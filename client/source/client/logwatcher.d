/// VRChat log file watcher
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.logwatcher;

import std.file : dirEntries, SpanMode, exists, DirEntry;
import std.path : buildPath, expandTilde;
import std.stdio : File;
import std.string : indexOf;
import std.algorithm : sort;

import core.thread;

import bindbc.sdl;
import ddlogger;

import client.state : MessageQueue;

/// Log event types emitted by the watcher.
enum LogEvent : string
{
    playerJoined  = "player-joined",
    playerLeft    = "player-left",
    locationChange = "location-change",
}

/// Watches VRChat output_log files for player join/leave events.
/// Runs on a background thread and pushes events into a MessageQueue.
class LogWatcher
{
    private Thread thread;
    private shared bool running;
    private MessageQueue queue;
    private uint sdlEventType;

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
        if (thread !is null)
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
                        pushLocationEvent(location);
                }
            }
            return;
        }

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
            string displayName = stripUserId(rest);

            if (displayName.length > 0)
                pushEvent(LogEvent.playerJoined, displayName);
            return;
        }

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
            string displayName = stripUserId(rest);

            if (displayName.length > 0)
                pushEvent(LogEvent.playerLeft, displayName);
            return;
        }
    }

    /// Strip trailing whitespace/newline.
    private static string stripRight(string s)
    {
        size_t end = s.length;
        while (end > 0 && (s[end - 1] == '\n' || s[end - 1] == '\r' || s[end - 1] == ' '))
            --end;
        return s[0 .. end];
    }

    /// Strip trailing " (usr_...)" from display name if present.
    private static string stripUserId(string s)
    {
        // Format: "DisplayName (usr_xxxxxxxx-...)"
        if (s.length > 0 && s[$ - 1] == ')')
        {
            ptrdiff_t parenIdx = indexOf(s, " (usr_");
            if (parenIdx > 0)
                return s[0 .. parenIdx];
        }
        return s;
    }

    /// Push a player join/leave event into the shared queue.
    private void pushEvent(LogEvent event, string displayName)
    {
        import std.json : JSONValue, JSONType;

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
        import std.json : JSONValue, JSONType;

        JSONValue msg = JSONValue(string[string].init);
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) LogEvent.locationChange;
        msg["location"] = location;

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
