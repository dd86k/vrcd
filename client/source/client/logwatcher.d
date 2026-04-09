/// VRChat log file watcher
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.logwatcher;

import std.file : dirEntries, SpanMode, exists, DirEntry;
import std.path : buildPath, expandTilde;
import std.stdio : File;
import std.string : indexOf, stripRight;
import std.algorithm : sort, remove, countUntil;
import std.array : replace;
import std.json : JSONValue;

import core.thread;

import bindbc.sdl;
import ddlogger;

import client.state : MessageQueue;
import client.png : writeDescriptionChunk;

/// Log event types emitted by the watcher.
enum LogEvent : string
{
    playerJoined  = "player-joined",
    playerLeft    = "player-left",
    locationChange = "location-change",
    photoTaken    = "photo-taken",
}

/// A tracked player in the current instance.
private struct TrackedPlayer
{
    string displayName;
    string userId; // may be empty if not present in log line
}

/// Watches VRChat output_log files for player join/leave events.
/// Runs on a background thread and pushes events into a MessageQueue.
class LogWatcher
{
    private Thread thread;
    private shared bool running;
    private MessageQueue queue;
    private uint sdlEventType;

    // Local state maintained from parsed log lines.
    private string currentLocation;
    private TrackedPlayer[] currentPlayers;

    this(MessageQueue queue, uint sdlEventType)
    {
        this.queue = queue;
        this.sdlEventType = sdlEventType;
    }

    void start()
    {
        running = true;
        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    void stop()
    {
        running = false;
    }

    void join()
    {
        if (thread)
        {
            thread.join();
            thread = null;
        }
    }

    private void run()
    {
        string logDir = vrchatLogDir();
        if (logDir.length == 0 || exists(logDir) == false)
        {
            logInfo("VRChat log directory not found, log watcher disabled");
            return;
        }

        // Track position per file.
        long[string] filePositions;

        while (running)
        {
            try
            {
                pollLogs(logDir, filePositions);
            }
            catch (Exception e)
            {
                logError("Log watcher error: %s", e.msg);
            }

            // Poll every second, matching VRCX.
            Thread.sleep(1.seconds);
        }
    }

    /// Poll all output_log files for new lines.
    private void pollLogs(string logDir, ref long[string] filePositions)
    {
        // Find log files and sort by name (contains timestamp).
        DirEntry[] logFiles;
        foreach (DirEntry entry; dirEntries(logDir, "output_log_*.txt", SpanMode.shallow))
            logFiles ~= entry;

        if (logFiles.length == 0)
            return;

        sort!((DirEntry a, DirEntry b) => a.name < b.name)(logFiles);

        // Only watch the most recent log file (the active VRChat session).
        DirEntry latest = logFiles[$ - 1];

        long pos;
        if (latest.name in filePositions)
            pos = filePositions[latest.name];
        else
        {
            // First time seeing this file: skip to end so we only see new events.
            pos = latest.size;
            filePositions[latest.name] = pos;
            return;
        }

        // Check if file has grown.
        if (latest.size <= pos)
            return;

        try
        {
            File f = File(latest.name, "r");
            f.seek(pos);
            char[] buf;
            while (f.readln(buf))
            {
                string line = cast(string) buf;
                parseLine(line);
            }
            filePositions[latest.name] = f.tell();
            f.close();
        }
        catch (Exception e)
        {
            logError("Failed to read log file %s: %s", latest.name, e.msg);
        }
    }

    /// Parse a single log line for player join/leave events.
    private void parseLine(string line)
    {
        // VRChat log format:
        // 2021.12.12 11:47:22 Log        -  [Behaviour] OnPlayerJoined DisplayName
        // 2021.12.12 11:47:22 Log        -  [Behaviour] OnPlayerJoined DisplayName (usr_xxx)
        // 2021.12.12 11:53:14 Log        -  [Behaviour] OnPlayerLeft DisplayName
        // Skip malformed lines.
        if (line.length <= 36 || line[31] != '-')
            return;

        // Check for [Behaviour] marker at offset 34.
        if (line.length <= 34 || line[34] != '[')
            return;

        // Event: Someone is joining instance (friends only?)
        // Check for room join: [Behaviour] Joining wrld_xxx:12345~region(us)
        // Skip "[Behaviour] Joining or Creating Room:" and "[Behaviour] Joining friend:".
        ptrdiff_t joiningIdx = indexOf(line, "[Behaviour] Joining ");
        if (joiningIdx >= 0 &&
            indexOf(line, "] Joining or Creating Room:") < 0 &&
            indexOf(line, "] Joining friend:") < 0)
        {
            ptrdiff_t locStart = indexOf(line, "] Joining ");
            if (locStart >= 0)
            {
                locStart += 10; // length of "] Joining "
                if (locStart < cast(ptrdiff_t) line.length)
                {
                    string location = stripRight(line[locStart .. $]);
                    if (location.length > 0)
                    {
                        currentLocation = location;
                        currentPlayers = null;
                        pushLocationEvent(location);
                    }
                }
            }
            return;
        }

        // Event: Player joined instance
        ptrdiff_t joinIdx = indexOf(line, "[Behaviour] OnPlayerJoined");
        if (joinIdx >= 0)
        {
            // Skip "OnPlayerJoined:" (unnamed variant).
            if (indexOf(line, "] OnPlayerJoined:") >= 0)
                return;

            // Extract display name after "OnPlayerJoined ".
            ptrdiff_t nameStart = indexOf(line, "] OnPlayerJoined");
            if (nameStart < 0)
                return;
            nameStart += 17; // length of "] OnPlayerJoined "
            if (nameStart >= cast(ptrdiff_t) line.length)
                return;

            string rest = stripRight(line[nameStart .. $]);
            string displayName;
            string userId;
            splitPlayer(rest, displayName, userId);

            if (displayName.length > 0)
            {
                addPlayer(displayName, userId);
                pushEvent(LogEvent.playerJoined, displayName);
            }
            return;
        }

        // Event: Player left instance
        ptrdiff_t leftIdx = indexOf(line, "[Behaviour] OnPlayerLeft");
        if (leftIdx >= 0)
        {
            // Skip "OnPlayerLeftRoom" and "OnPlayerLeft:" variants.
            if (indexOf(line, "] OnPlayerLeftRoom") >= 0 ||
                indexOf(line, "] OnPlayerLeft:") >= 0)
                return;

            ptrdiff_t nameStart = indexOf(line, "] OnPlayerLeft");
            if (nameStart < 0)
                return;
            nameStart += 15; // length of "] OnPlayerLeft "
            if (nameStart >= cast(ptrdiff_t) line.length)
                return;

            string rest = stripRight(line[nameStart .. $]);
            string displayName;
            string userId;
            splitPlayer(rest, displayName, userId);

            if (displayName.length > 0)
            {
                removePlayer(displayName);
                pushEvent(LogEvent.playerLeft, displayName);
            }
            return;
        }
        
        // Event: Photo taken
        // VRChat always logs a Windows-style path, even under Proton on Linux:
        //   2026.04.08 14:41:22 Log        -  [VRC Camera] Took screenshot to: PATH
        //   PATH: C:\users\steamuser\Pictures\VRChat\2026-04\VRChat_2026-04-08_14-41-22.851_2560x1440.png
        enum string photoMarker = "[VRC Camera] Took screenshot to: ";
        ptrdiff_t photoIdx = indexOf(line, photoMarker);
        if (photoIdx >= 0)
        {
            size_t pathStart = cast(size_t)(photoIdx + photoMarker.length);
            if (pathStart >= line.length)
                return;
            string logPath = stripRight(line[pathStart .. $]);
            if (logPath.length == 0)
                return;

            string localPath = translateVRChatPath(logPath);
            string metaJson = buildMetadataJson();

            // Write metadata in a background thread so the log watcher keeps up
            // with events while we wait for VRChat to release the file lock.
            startMetadataWrite(localPath, metaJson);

            pushPhotoEvent(localPath);
            return;
        }
    }

    /// Add a player to the local instance roster (no-op if already present).
    private void addPlayer(string displayName, string userId)
    {
        foreach (ref TrackedPlayer p; currentPlayers)
        {
            if (p.displayName == displayName)
            {
                if (p.userId.length == 0 && userId.length > 0)
                    p.userId = userId;
                return;
            }
        }
        currentPlayers ~= TrackedPlayer(displayName, userId);
    }

    /// Remove a player from the local instance roster by display name.
    private void removePlayer(string displayName)
    {
        ptrdiff_t idx = countUntil!((TrackedPlayer p) => p.displayName == displayName)(currentPlayers);
        if (idx >= 0)
            currentPlayers = currentPlayers.remove(idx);
    }

    /// Build a VRCX-compatible metadata JSON string from current local state.
    private string buildMetadataJson()
    {
        JSONValue msg = JSONValue(string[string].init);
        msg["application"] = "vrcddlogger";
        msg["version"] = 1;

        if (currentLocation.length > 0)
        {
            JSONValue world = JSONValue(string[string].init);
            world["instanceId"] = currentLocation;
            ptrdiff_t colon = indexOf(currentLocation, ':');
            if (colon > 0)
                world["id"] = currentLocation[0 .. colon];
            msg["world"] = world;
        }

        JSONValue players = JSONValue((JSONValue[]).init);
        foreach (ref TrackedPlayer p; currentPlayers)
        {
            JSONValue pj = JSONValue(string[string].init);
            pj["displayName"] = p.displayName;
            if (p.userId.length > 0)
                pj["id"] = p.userId;
            players.array ~= pj;
        }
        msg["players"] = players;

        return msg.toString();
    }

    /// Spawn a short-lived background thread that waits for VRChat to release
    /// the screenshot file, then writes the Description iTXt chunk.
    private static void startMetadataWrite(string path, string jsonText)
    {
        Thread t = new Thread({
            // Retry for ~10 seconds while VRChat holds the file.
            foreach (int i; 0 .. 20)
            {
                try
                {
                    writeDescriptionChunk(path, jsonText);
                    logInfo("Wrote screenshot metadata: %s", path);
                    return;
                }
                catch (Exception e)
                {
                    Thread.sleep(500.msecs);
                }
            }
            logError("Failed to write screenshot metadata after retries: %s", path);
        });
        t.isDaemon = true;
        t.start();
    }

    /// Split "DisplayName (usr_...)" into display name and user id.
    /// If no user id is present, userId is left empty.
    private static void splitPlayer(string s, out string displayName, out string userId)
    {
        if (s.length > 0 && s[$ - 1] == ')')
        {
            ptrdiff_t parenIdx = indexOf(s, " (usr_");
            if (parenIdx > 0)
            {
                displayName = s[0 .. parenIdx];
                userId = s[parenIdx + 2 .. $ - 1]; // strip " (" prefix and ")" suffix
                return;
            }
        }
        displayName = s;
    }

    /// Push a player join/leave event into the shared queue.
    private void pushEvent(LogEvent event, string displayName)
    {
        JSONValue msg = JSONValue(string[string].init);
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) event;
        msg["display_name"] = displayName;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Push a location change event into the shared queue.
    private void pushLocationEvent(string location)
    {
        JSONValue msg = JSONValue(string[string].init);
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) LogEvent.locationChange;
        msg["location"] = location;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Push a photo-taken event into the shared queue.
    private void pushPhotoEvent(string path)
    {
        JSONValue msg = JSONValue(string[string].init);
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) LogEvent.photoTaken;
        msg["path"] = path;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Push an SDL event to wake the main thread.
    private void pushWakeEvent()
    {
        SDL_Event ev;
        ev.type = sdlEventType;
        SDL_PushEvent(&ev);
    }
}

/// Return the VRChat log directory for the current platform.
private string vrchatLogDir()
{
    version (Windows)
    {
        import std.process : environment;
        string localAppData = environment.get("LOCALAPPDATA", "");
        if (localAppData.length == 0)
            return "";
        return buildPath(localAppData ~ "Low", "VRChat", "VRChat");
    }
    else
    {
        return expandTilde(
            "~/.steam/steam/steamapps/compatdata/438100/pfx/drive_c/users/steamuser/AppData/LocalLow/VRChat/VRChat"
        );
    }
}

/// Translate a Windows-flavoured path from the VRChat log into a local path.
/// On Windows this is a no-op; on Linux it remaps "C:\..." into the Proton
/// prefix used for the VRChat install.
private string translateVRChatPath(string logPath)
{
    version (Windows)
    {
        return logPath;
    }
    else
    {
        // Expect something like "C:\users\steamuser\Pictures\VRChat\...".
        if (logPath.length < 3 || logPath[1] != ':')
            return logPath;
        char sep = logPath[2];
        if (sep != '\\' && sep != '/')
            return logPath;
        // Strip drive letter and normalise separators.
        string tail = logPath[2 .. $].replace("\\", "/");
        string prefix = expandTilde(
            "~/.steam/steam/steamapps/compatdata/438100/pfx/drive_c"
        );
        return prefix ~ tail;
    }
}
