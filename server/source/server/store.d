/// Event store
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.store;

import std.file : exists, mkdirRecurse;
import std.path : dirName;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;

import ddlogger;
import arsd.sqlite;

import server.events;

// NOTE: Database structure
//       Right now, it's mostly just logging events as-is.
//
//       Tables:
//       - ws_events: Raw events from VRC WS.
//       - ws_connection_log: Logs when server connects to VRC WS API.
//         TODO: Confirm if used for rate-limiting.
//       - server_state: Unused so far.
//       - VRCX tables: Compat. Prefixed with user ID.

/// SQLite event store.
class EventStore
{
    private Sqlite db;

    this(string dbPath)
    {
        string dir = dirName(dbPath);
        if (!exists(dir))
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

        // Raw event log — canonical append-only stream.
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

        // Connection log for gap tracking.
        db.exec(
            "CREATE TABLE IF NOT EXISTS ws_connection_log (" ~
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
            "  timestamp TEXT NOT NULL," ~
            "  event TEXT NOT NULL" ~
            ")"
        );

        // Server state key-value store.
        db.exec(
            "CREATE TABLE IF NOT EXISTS server_state (" ~
            "  key TEXT PRIMARY KEY," ~
            "  value TEXT" ~
            ")"
        );

        // VRCX-compatible tables (global).
        initVRCXGlobalTables();

        logInfo("Database schema ready");
    }

    void initVRCXGlobalTables()
    {
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
    }

    /// Create per-user VRCX-compatible tables.
    /// Call this after authentication when the user ID is known.
    public void initUserTables(string userId)
    {
        import std.string : replace;
        // VRCX uses the user ID as prefix, sanitized.
        string prefix = userId.replace("-", "_");
        logDebugging("initUserTables: userId=%s prefix=%s", userId, prefix);

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_feed_gps (" ~
            "  id INTEGER PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  user_id TEXT," ~
            "  display_name TEXT," ~
            "  location TEXT," ~
            "  world_name TEXT," ~
            "  previous_location TEXT," ~
            "  time INTEGER," ~
            "  group_name TEXT" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_feed_status (" ~
            "  id INTEGER PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  user_id TEXT," ~
            "  display_name TEXT," ~
            "  status TEXT," ~
            "  status_description TEXT," ~
            "  previous_status TEXT," ~
            "  previous_status_description TEXT" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_feed_bio (" ~
            "  id INTEGER PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  user_id TEXT," ~
            "  display_name TEXT," ~
            "  bio TEXT," ~
            "  previous_bio TEXT" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_feed_avatar (" ~
            "  id INTEGER PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  user_id TEXT," ~
            "  display_name TEXT," ~
            "  owner_id TEXT," ~
            "  avatar_name TEXT," ~
            "  current_avatar_image_url TEXT," ~
            "  current_avatar_thumbnail_image_url TEXT," ~
            "  previous_current_avatar_image_url TEXT," ~
            "  previous_current_avatar_thumbnail_image_url TEXT" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_feed_online_offline (" ~
            "  id INTEGER PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  user_id TEXT," ~
            "  display_name TEXT," ~
            "  type TEXT," ~
            "  location TEXT," ~
            "  world_name TEXT," ~
            "  time INTEGER," ~
            "  group_name TEXT" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_friend_log_current (" ~
            "  user_id TEXT PRIMARY KEY," ~
            "  display_name TEXT," ~
            "  trust_level TEXT," ~
            "  friend_number INTEGER" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_friend_log_history (" ~
            "  id INTEGER PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  type TEXT," ~
            "  user_id TEXT," ~
            "  display_name TEXT," ~
            "  previous_display_name TEXT," ~
            "  trust_level TEXT," ~
            "  previous_trust_level TEXT," ~
            "  friend_number INTEGER" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_notifications (" ~
            "  id TEXT PRIMARY KEY," ~
            "  created_at TEXT," ~
            "  type TEXT," ~
            "  sender_user_id TEXT," ~
            "  sender_username TEXT," ~
            "  receiver_user_id TEXT," ~
            "  message TEXT," ~
            "  world_id TEXT," ~
            "  world_name TEXT," ~
            "  image_url TEXT," ~
            "  invite_message TEXT," ~
            "  request_message TEXT," ~
            "  response_message TEXT," ~
            "  expired INTEGER" ~
            ")"
        );

        db.exec(
            "CREATE TABLE IF NOT EXISTS " ~ prefix ~ "_moderation (" ~
            "  user_id TEXT PRIMARY KEY," ~
            "  updated_at TEXT," ~
            "  display_name TEXT," ~
            "  block INTEGER," ~
            "  mute INTEGER" ~
            ")"
        );
    }
}

private string toISO(SysTime t)
{
    return t.toUTC().toISOExtString();
}
