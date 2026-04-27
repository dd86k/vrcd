/// VRChat log file watcher
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.logwatcher;

import std.file : dirEntries, SpanMode, exists, DirEntry;
import std.path : buildPath;
import std.stdio : File;
import std.string : indexOf, stripRight;
import std.algorithm : sort, remove, countUntil;
import std.json : JSONValue;

import core.thread;

import bindbc.sdl;
import ddlogger;

import client.state : MessageQueue;
import client.png : writeDescriptionChunk;
import client.directories : vrchatLogDir, translateVRChatPath;

/// Log event types emitted by the watcher.
enum LogEvent : string
{
    playerJoined    = "player-joined",
    playerLeft      = "player-left",
    locationChange  = "location-change",
    photoTaken      = "photo-taken",
    urlVideo        = "url-video",
    urlString       = "url-string",
    urlImage        = "url-image",
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
    shared bool writeMetadata = true;
    private MessageQueue queue;
    private uint sdlEventType;

    // Local state maintained from parsed log lines.
    private string currentLocation;
    private string currentWorldName;
    private TrackedPlayer[] currentPlayers;
    private TrackedPlayer localUser;

    // While true, parseLine updates state but suppresses all outward-facing
    // side effects (events, metadata writes). Used during initial backfill
    // so we rebuild state from an existing log file without replaying old
    // events to the UI.
    private bool silent;

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
        logDebugging("LogWatcher: resolved log dir=%s", logDir);
        if (logDir.length == 0 || exists(logDir) == false)
        {
            logInfo("VRChat log directory not found, log watcher disabled");
            return;
        }
        logInfo("LogWatcher: watching %s", logDir);

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
            // First time seeing this file: scan the whole thing silently to
            // rebuild state (local user, current world, roster) from history,
            // then track from the end so only new events generate output.
            pos = backfillFromFile(latest.name);
            filePositions[latest.name] = pos;
            logDebugging("LogWatcher: backfilled %s up to offset %d",
                latest.name, pos);
            return;
        }

        // Check if file has grown.
        if (latest.size <= pos)
            return;

        logTrace("LogWatcher: %s grew from %d to %d", latest.name, pos, latest.size);
        try
        {
            File f = File(latest.name, "r");
            f.seek(pos);
            char[] buf;
            while (f.readln(buf))
            {
                // buf is reused by readln across iterations, so any slice
                // of `line` that outlives this call must be idup'd by the
                // consumer (see addPlayer, Joining/Entering Room handlers).
                string line = cast(string) buf;
                parseLine(line);
            }
            long newPos = f.tell();
            filePositions[latest.name] = newPos;
            f.close();
            logTrace("LogWatcher: advanced position to %d", newPos);
        }
        catch (Exception e)
        {
            logError("Failed to read log file %s: %s", latest.name, e.msg);
        }
    }

    /// Silently replay an existing log file to rebuild state without firing
    /// events or writing metadata. Returns the file offset at end of scan so
    /// the caller can resume live tailing from there.
    private long backfillFromFile(string path)
    {
        silent = true;
        scope (exit) silent = false;
        try
        {
            File f = File(path, "r");
            char[] buf;
            while (f.readln(buf))
            {
                string line = cast(string) buf;
                parseLine(line);
            }
            long end = f.tell();
            f.close();
            logDebugging("LogWatcher: backfill complete user='%s' world='%s' location='%s' players=%d",
                localUser.displayName, currentWorldName, currentLocation, currentPlayers.length);
            return end;
        }
        catch (Exception e)
        {
            logError("Failed to backfill from %s: %s", path, e.msg);
            try
                return DirEntry(path).size;
            catch (Exception)
                return 0;
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

        // Event: Local user authenticated with VRChat. Logged near the top of
        // every session, e.g.
        //   2026.04.10 17:05:07 Debug      -  User Authenticated: dd86k (usr_xxx)
        // Does not have a [Behaviour] marker, so handle before the fast-path.
        enum string authMarker = "User Authenticated: ";
        ptrdiff_t authIdx = indexOf(line, authMarker);
        if (authIdx == 34) // should only happen once
        {
            string rest = stripRight(line[authIdx + authMarker.length .. $]);
            string displayName;
            string userId;
            splitPlayer(rest, displayName, userId);
            if (displayName.length > 0 && userId.length > 0)
            {
                logDebugging("LogWatcher: local user authenticated as '%s' (%s)",
                    displayName, userId);
                localUser = TrackedPlayer(displayName.idup, userId.idup);
            }
            return;
        }

        // Check for [Behaviour] marker at offset 34.
        if (line[34] != '[')
            return;

        // Event: Entering Room, which gives us the human-readable world name.
        // This fires immediately before the "Joining wrld_..." line.
        enum string enterMarker = "[Behaviour] Entering Room: ";
        ptrdiff_t enterIdx = indexOf(line, enterMarker);
        if (enterIdx >= 0)
        {
            string name = stripRight(line[enterIdx + enterMarker.length .. $]);
            if (name.length > 0)
            {
                logDebugging("LogWatcher: entering room '%s'", name);
                currentWorldName = name.idup;
            }
            return;
        }

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
                        logDebugging("LogWatcher: joining instance %s", location);
                        currentLocation = location.idup;
                        currentPlayers = null;
                        pushLocationEvent(currentLocation);
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
                logDebugging("LogWatcher: player joined '%s' (id=%s) now=%d players",
                    displayName, userId, currentPlayers.length + 1);
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
                logDebugging("LogWatcher: player left '%s' (id=%s)",
                    displayName, userId);
                removePlayer(displayName);
                pushEvent(LogEvent.playerLeft, displayName);
            }
            return;
        }
        
        // Event: Video playback URL
        // Several log formats exist:
        //   [Video Playback] Attempting to resolve URL 'https://...'
        //   [Video Playback] Resolving URL 'https://...'
        //   User DisplayName added URL https://...
        //   [USharpVideo] Started video load for URL: https://..., requested by DisplayName
        string videoUrl;
        string videoUser;

        enum string vpAttemptMarker = "[Video Playback] Attempting to resolve URL '";
        enum string vpResolveMarker = "[Video Playback] Resolving URL '";
        enum string usharpMarker = "[USharpVideo] Started video load for URL: ";

        ptrdiff_t vpAttemptIdx = indexOf(line, vpAttemptMarker);
        if (vpAttemptIdx >= 0)
        {
            string rest = stripRight(line[vpAttemptIdx + vpAttemptMarker.length .. $]);
            if (rest.length > 0 && rest[$ - 1] == '\'')
                videoUrl = rest[0 .. $ - 1].idup;
        }

        if (videoUrl.length == 0)
        {
            ptrdiff_t vpResolveIdx = indexOf(line, vpResolveMarker);
            if (vpResolveIdx >= 0)
            {
                string rest = stripRight(line[vpResolveIdx + vpResolveMarker.length .. $]);
                if (rest.length > 0 && rest[$ - 1] == '\'')
                    videoUrl = rest[0 .. $ - 1].idup;
            }
        }

        if (videoUrl.length == 0)
        {
            ptrdiff_t usharpIdx = indexOf(line, usharpMarker);
            if (usharpIdx >= 0)
            {
                string rest = stripRight(line[usharpIdx + usharpMarker.length .. $]);
                ptrdiff_t reqIdx = indexOf(rest, ", requested by ");
                if (reqIdx > 0)
                {
                    videoUrl = rest[0 .. reqIdx].idup;
                    videoUser = rest[reqIdx + 15 .. $].idup;
                }
            }
        }

        if (videoUrl.length == 0)
        {
            ptrdiff_t addedIdx = indexOf(line, " added URL ");
            if (addedIdx >= 0 && addedIdx > 34)
            {
                // "User DisplayName added URL https://..."
                // The "User " prefix starts at offset 34.
                enum string userPrefix = "User ";
                ptrdiff_t userIdx = indexOf(line, userPrefix);
                if (userIdx == 34)
                {
                    videoUser = line[userIdx + userPrefix.length .. addedIdx].idup;
                    videoUrl = stripRight(line[addedIdx + 11 .. $]).idup;
                }
            }
        }

        if (videoUrl.length > 0)
        {
            logDebugging("LogWatcher: url-video url=%s user=%s", videoUrl, videoUser);
            pushUrlEvent(LogEvent.urlVideo, videoUrl, videoUser);
            return;
        }

        // Event: String download
        //   [String Download] Attempting to load String from URL 'https://...'
        enum string stringDlMarker = "] Attempting to load String from URL '";
        ptrdiff_t stringDlIdx = indexOf(line, stringDlMarker);
        if (stringDlIdx >= 0)
        {
            string rest = stripRight(line[stringDlIdx + stringDlMarker.length .. $]);
            if (rest.length > 0 && rest[$ - 1] == '\'')
            {
                string url = rest[0 .. $ - 1].idup;
                if (isLocalRequest(url) == false)
                {
                    logDebugging("LogWatcher: resource-load-string url=%s", url);
                    pushUrlEvent(LogEvent.urlString, url, "");
                }
            }
            return;
        }

        // Event: Image download
        //   [Image Download] Attempting to load image from URL 'https://...'
        enum string imageDlMarker = "] Attempting to load image from URL '";
        ptrdiff_t imageDlIdx = indexOf(line, imageDlMarker);
        if (imageDlIdx >= 0)
        {
            string rest = stripRight(line[imageDlIdx + imageDlMarker.length .. $]);
            if (rest.length > 0 && rest[$ - 1] == '\'')
            {
                string url = rest[0 .. $ - 1].idup;
                if (isLocalRequest(url) == false)
                {
                    logDebugging("LogWatcher: resource-load-image url=%s", url);
                    pushUrlEvent(LogEvent.urlImage, url, "");
                }
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
            // Skip old photos replayed during backfill,  VRChat has long
            // since closed the file and we don't want to rewrite metadata
            // for historical screenshots.
            if (silent)
                return;
            size_t pathStart = cast(size_t)(photoIdx + photoMarker.length);
            if (pathStart >= line.length)
                return;
            string logPath = stripRight(line[pathStart .. $]);
            if (logPath.length == 0)
                return;

            string localPath = translateVRChatPath(logPath);
            logDebugging("LogWatcher: photo-taken logPath=%s localPath=%s writeMetadata=%s",
                logPath, localPath, writeMetadata);

            // Write metadata in a background thread so the log watcher keeps up
            // with events while we wait for VRChat to release the file lock.
            if (writeMetadata)
            {
                string metaJson = buildMetadataJson();
                startMetadataWrite(localPath, metaJson);
            }

            pushPhotoEvent(localPath);
            return;
        }
    }

    /// Add a player to the local instance roster (no-op if already present).
    /// Strings are idup'd so they don't alias the reusable readln buffer.
    private void addPlayer(string displayName, string userId)
    {
        foreach (ref TrackedPlayer p; currentPlayers)
        {
            if (p.displayName == displayName)
            {
                if (p.userId.length == 0 && userId.length > 0)
                    p.userId = userId.idup;
                return;
            }
        }
        currentPlayers ~= TrackedPlayer(displayName.idup, userId.idup);
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
        msg["application"] = "vrcd";
        msg["version"] = 1;

        if (localUser.displayName.length > 0)
        {
            JSONValue author = JSONValue(string[string].init);
            author["displayName"] = localUser.displayName;
            if (localUser.userId.length > 0)
                author["id"] = localUser.userId;
            msg["author"] = author;
        }

        if (currentLocation.length > 0)
        {
            JSONValue world = JSONValue(string[string].init);
            world["instanceId"] = currentLocation;
            ptrdiff_t colon = indexOf(currentLocation, ':');
            if (colon > 0)
                world["id"] = currentLocation[0 .. colon];
            if (currentWorldName.length > 0)
                world["name"] = currentWorldName;
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
            logDebugging("startMetadataWrite: spawning writer for %s", path);
            
            // Retry 10 times with 2 second sleeps
            string emsg;
            foreach (int i; 0 .. 10)
            {
                try
                {
                    writeDescriptionChunk(path, jsonText);
                    logInfo("Wrote screenshot metadata: %s", path);
                    return;
                }
                catch (Exception ex)
                {
                    Thread.sleep(2000.msecs);
                    emsg = ex.msg; // only last is meaningful
                }
            }
            logError("Failed to write picture metadata to '%s': %s", path, emsg);
            
            // At least try writing metadata next to the file
            import std.file : write;
            string jsonpath = path~".json";
            try
            {
                write(jsonpath, jsonText);
                logInfo("Wrote metadata fallback to '%s'", jsonpath);
            }
            catch (Exception ex)
            {
                // At this point, we can only scream
                logError("Failed to write metadata fallback to '%s': %s", jsonpath, ex.msg);
            }
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
        if (silent)
            return;

        // I think we know when we do something
        if (localUser.displayName && displayName == localUser.displayName)
            return;

        JSONValue msg;
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) event;
        msg["display_name"] = displayName;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Push a location change event into the shared queue.
    private void pushLocationEvent(string location)
    {
        if (silent)
            return;
        JSONValue msg; // curious why it was init to JSONValue(string[string].init);
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) LogEvent.locationChange;
        msg["location"] = location;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Push a photo-taken event into the shared queue.
    private void pushPhotoEvent(string path)
    {
        if (silent)
            return;

        JSONValue msg;
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) LogEvent.photoTaken;
        msg["path"] = path;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Push a URL load event (video, string, image) into the shared queue.
    private void pushUrlEvent(LogEvent event, string url, string user)
    {
        if (silent)
            return;

        JSONValue msg;
        msg["type"] = "log-event";
        msg["event_type"] = cast(string) event;
        msg["url"] = url;
        if (user.length > 0)
            msg["display_name"] = user;

        queue.pushMessage(msg.toString());
        pushWakeEvent();
    }

    /// Check if a URL is a local request (VRCX/localhost) that should be ignored.
    private static bool isLocalRequest(string url)
    {
        return indexOf(url, "http://127.0.0.1:22500") == 0 ||
               indexOf(url, "http://localhost:22500") == 0;
    }

    /// Push an SDL event to wake the main thread.
    private void pushWakeEvent()
    {
        SDL_Event ev = void;
        ev.type = sdlEventType;
        SDL_PushEvent(&ev);
    }
}

