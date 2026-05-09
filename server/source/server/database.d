/// Database
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.database;

import std.file : exists, mkdirRecurse;
import std.path : dirName;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;

import ddlogger;
import arsd.sqlite;

import server.events;

// Database structure
//
// Tables:
// - ws_events        : Append-only event log. Holds both raw VRChat WS events and
//                      synthetic events derived by the server (e.g. avatar-change).
//                      The `source` column distinguishes them ("raw" vs "synthetic").
// - ws_connection_log: Records when the server connects/disconnects from VRC WS.
//                      Used to detect gaps in the event stream.
// - server_state     : Key-value store for persistent server state.
// - cache_world      : VRChat world metadata cache (name, author, thumbnail, etc.).
// - cache_avatar     : VRChat avatar metadata cache.

/// Server statistics returned by Database.getStats().
struct DatabaseStats
{
    long eventCount;
    long worldCacheCount;
    long avatarCacheCount;
    long dbSizeBytes;
}

// Returns "raw" or "synthetic".
//
// raw events are events directly coming from the server (ie, VRChat).
//
// synthetic events are purely created by the server for consistency.
private
string eventSource(EventType type)
{
    switch (type) {
    case EventType.avatarChange:
        return "synthetic";
    default:
        return "raw";
    }
}

/// SQLite database.
class Database
{
    private Sqlite db;

    this(string dbPath)
    {
        string dir = dirName(dbPath);
        if (exists(dir) == false)
            mkdirRecurse(dir);

        db = new Sqlite(dbPath);

        // Enable WAL for concurrent read/write.
        // HACK: Adam's AWESOME sqlite library segfaults on db.exec
        //       Because PRAGMA returns a row and since result callback (onExec) is null,
        //       then the unreferenced function null pointer is called.
        foreach (_; db.query("PRAGMA journal_mode=WAL")) {}

        initSchema();
    }

    /// Store a raw WebSocket event. Returns the assigned event ID.
    long storeEvent(VRCEvent event)
    {
        logTrace("storeEvent: type=%s contentLen=%d rawLen=%d",
            event.typeRaw, event.content.toString().length, event.rawJson.length);

        foreach (_; db.query(
            "INSERT INTO ws_events (received_at, event_type, source, raw_json) VALUES (?, ?, ?, ?)",
            toISO(event.receivedAt),
            event.typeRaw,
            eventSource(event.type),
            event.rawJson,
        )) {}

        // Get last insert rowid.
        foreach (row; db.query("SELECT last_insert_rowid()"))
        {
            long id = row[0].to!long;
            logDebugging("storeEvent: assigned id=%d type=%s", id, event.typeRaw);
            return id;
        }

        return -1;
    }

    /// Query events after a given ID (for client catch-up).
    auto queryEventsAfter(long afterId, int limit = 1000)
    {
        logDebugging("queryEventsAfter: afterId=%d limit=%d", afterId, limit);
        return db.query(
            "SELECT id, received_at, event_type, raw_json FROM ws_events WHERE id > ? ORDER BY id ASC LIMIT ?",
            afterId.to!string,
            limit.to!string,
        );
    }

    /// Query events before a given ID, newest first (for client back-fill).
    auto queryEventsBefore(long beforeId, int limit = 100)
    {
        logDebugging("queryEventsBefore: beforeId=%d limit=%d", beforeId, limit);
        return db.query(
            "SELECT id, received_at, event_type, raw_json FROM ws_events WHERE id < ? ORDER BY id DESC LIMIT ?",
            beforeId.to!string,
            limit.to!string,
        );
    }

    /// Query recent events (for CLI viewer).
    auto queryRecentEvents(int limit = 50)
    {
        return db.query(
            "SELECT id, received_at, event_type, raw_json FROM ws_events ORDER BY id DESC LIMIT ?",
            limit.to!string,
        );
    }

    /// Get the latest event ID (for state tracking).
    long getLatestEventId()
    {
        foreach (row; db.query("SELECT MAX(id) FROM ws_events"))
        {
            string val = row[0];
            if (val.length > 0)
                return val.to!long;
        }
        return 0;
    }

    /// Log a WebSocket connection event.
    void logConnection(string eventType)
    {
        logDebugging("logConnection: %s", eventType);
        foreach (_; db.query(
            "INSERT INTO ws_connection_log (timestamp, event) VALUES (datetime('now'), ?)",
            eventType,
        )) {}
    }

    /// Prune events older than the cutoff expressed as a SQLite datetime
    /// modifier (e.g. "-3 months"). Returns the number of rows deleted
    /// across ws_events and ws_connection_log.
    long pruneOldEvents(string modifier)
    {
        logInfo("Pruning events older than datetime('now', '%s')...", modifier);
        
        // Process WS events
        foreach (_; db.query(
            "DELETE FROM ws_events WHERE received_at < datetime('now', ?)",
            modifier,
        )) {}
        long deleted;
        foreach (row; db.query("SELECT changes()"))
            deleted = row[0].to!long;

        // Process WS connection logs
        foreach (_; db.query(
            "DELETE FROM ws_connection_log WHERE timestamp < datetime('now', ?)",
            modifier,
        )) {}
        // NOTE: Included connection logs in this number is asking for confusion.
        //       Why? Because "prune events" means "pruning WS events", not connection logs.
        //       If we really wanted this specifically, return a struct with
        //       connection_log number specifically.
        /*
        foreach (row; db.query("SELECT changes()"))
            deleted += row[0].to!long;
        */

        return deleted;
    }

    /// Collect server statistics.
    DatabaseStats getStats()
    {
        DatabaseStats stats;
        foreach (row; db.query("SELECT COUNT(*) FROM ws_events"))
            stats.eventCount = row[0].to!long;
        foreach (row; db.query("SELECT COUNT(*) FROM cache_world"))
            stats.worldCacheCount = row[0].to!long;
        foreach (row; db.query("SELECT COUNT(*) FROM cache_avatar"))
            stats.avatarCacheCount = row[0].to!long;
        long pageCount;
        long pageSize;
        foreach (row; db.query("PRAGMA page_count"))
            pageCount = row[0].to!long;
        foreach (row; db.query("PRAGMA page_size"))
            pageSize = row[0].to!long;
        stats.dbSizeBytes = pageCount * pageSize;
        return stats;
    }

    /// Close the database.
    void close()
    {
        // arsd Sqlite doesn't have an explicit close, but we can null it.
        db = null;
    }

private:
    void initSchema()
    {
        logInfo("Initializing database schema...");

        // Append-only event log (raw + synthetic).
        db.exec(
            "CREATE TABLE IF NOT EXISTS ws_events (" ~
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
            "  received_at TEXT NOT NULL," ~
            "  event_type TEXT NOT NULL," ~
            "  source TEXT," ~
            "  raw_json TEXT" ~
            ")"
        );

        // Migration: legacy databases have `content_json` instead of `source`.
        // The two columns serve different purposes, but `content_json` was
        // unconditionally NULL in recent versions, so renaming preserves no data
        // worth keeping while avoiding a full table rebuild.
        bool hasSource;
        bool hasContentJson;
        foreach (row; db.query("PRAGMA table_info(ws_events)"))
        {
            string name = row[1];
            if (name == "source")       hasSource = true;
            if (name == "content_json") hasContentJson = true;
        }
        if (hasSource == false && hasContentJson)
        {
            logInfo("Migrating ws_events: renaming content_json to source");
            db.exec("ALTER TABLE ws_events RENAME COLUMN content_json TO source");
        }

        // Index for catch-up queries.
        db.exec("CREATE INDEX IF NOT EXISTS idx_ws_events_type ON ws_events (event_type)");

        // Connection log for gap detection.
        db.exec(
            "CREATE TABLE IF NOT EXISTS ws_connection_log (" ~
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
            "  timestamp TEXT NOT NULL," ~
            "  event TEXT NOT NULL" ~
            ")"
        );

        // Persistent server state (key-value).
        db.exec(
            "CREATE TABLE IF NOT EXISTS server_state (" ~
            "  key TEXT PRIMARY KEY," ~
            "  value TEXT" ~
            ")"
        );

        // World metadata cache.
        db.exec(
            "CREATE TABLE IF NOT EXISTS cache_world (" ~
            "  id TEXT PRIMARY KEY," ~
            "  added_at TEXT," ~
            "  author_id TEXT," ~
            "  author_name TEXT," ~
            "  created_at TEXT," ~
            "  description TEXT," ~
            "  image_url TEXT," ~
            "  name TEXT," ~
            "  release_status TEXT," ~
            "  thumbnail_image_url TEXT," ~
            "  updated_at TEXT," ~
            "  version INTEGER" ~
            ")"
        );

        // Avatar metadata cache.
        db.exec(
            "CREATE TABLE IF NOT EXISTS cache_avatar (" ~
            "  id TEXT PRIMARY KEY," ~
            "  added_at TEXT," ~
            "  author_id TEXT," ~
            "  author_name TEXT," ~
            "  created_at TEXT," ~
            "  description TEXT," ~
            "  image_url TEXT," ~
            "  name TEXT," ~
            "  release_status TEXT," ~
            "  thumbnail_image_url TEXT," ~
            "  updated_at TEXT," ~
            "  version INTEGER" ~
            ")"
        );

        logInfo("Database schema ready");
    }
}

private string toISO(SysTime t)
{
    return t.toUTC().toISOExtString();
}
