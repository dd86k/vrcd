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
// - ws_events        : Canonical append-only log of raw VRChat WebSocket events.
// - ws_connection_log: Records when the server connects/disconnects from VRC WS.
//                      Used to detect gaps in the event stream.
// - server_state     : Key-value store for persistent server state.
// - cache_world      : VRChat world metadata cache (name, author, thumbnail, etc.).
// - cache_avatar     : VRChat avatar metadata cache.

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

        // Use query for parameterized statements.
        foreach (_; db.query(
            "INSERT INTO ws_events (received_at, event_type, content_json, raw_json) VALUES (?, ?, ?, ?)",
            toISO(event.receivedAt),
            event.typeRaw,
            event.content.toString(),
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
            "SELECT id, received_at, event_type, content_json FROM ws_events WHERE id > ? ORDER BY id ASC LIMIT ?",
            afterId.to!string,
            limit.to!string,
        );
    }

    /// Query events before a given ID, newest first (for client back-fill).
    auto queryEventsBefore(long beforeId, int limit = 100)
    {
        logDebugging("queryEventsBefore: beforeId=%d limit=%d", beforeId, limit);
        return db.query(
            "SELECT id, received_at, event_type, content_json FROM ws_events WHERE id < ? ORDER BY id DESC LIMIT ?",
            beforeId.to!string,
            limit.to!string,
        );
    }

    /// Query recent events (for CLI viewer).
    auto queryRecentEvents(int limit = 50)
    {
        return db.query(
            "SELECT id, received_at, event_type, content_json FROM ws_events ORDER BY id DESC LIMIT ?",
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
        foreach (_; db.query(
            "DELETE FROM ws_events WHERE received_at < datetime('now', ?)",
            modifier,
        )) {}
        long deleted;
        foreach (row; db.query("SELECT changes()"))
            deleted = row[0].to!long;

        foreach (_; db.query(
            "DELETE FROM ws_connection_log WHERE timestamp < datetime('now', ?)",
            modifier,
        )) {}
        foreach (row; db.query("SELECT changes()"))
            deleted += row[0].to!long;

        return deleted;
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

        // Canonical append-only event log.
        db.exec(
            "CREATE TABLE IF NOT EXISTS ws_events (" ~
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
            "  received_at TEXT NOT NULL," ~
            "  event_type TEXT NOT NULL," ~
            "  content_json TEXT," ~
            "  raw_json TEXT" ~
            ")"
        );

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
