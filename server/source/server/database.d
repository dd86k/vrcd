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
//                      Written through by server.worldcache, which keeps a
//                      memory tier in front of it. This is the tier that
//                      survives a restart.
// - cache_avatar     : VRChat avatar metadata cache. Schema only for now:
//                      nothing writes to it yet.

/// Server statistics returned by Database.getStats().
struct DatabaseStats
{
    long eventCount;
    long worldCacheCount;
    long avatarCacheCount;
    long dbSizeBytes;
}

/// One row of `cache_world`: VRChat's world metadata as it was last fetched.
///
/// `addedAt` is when the row was written, and is what decides whether it is
/// still worth believing: VRChat sends no events for a world being edited or
/// deleted, so age is the only thing this side has to go on.
struct CachedWorld
{
    /// False when the world is not in the table. The rest is then unset.
    bool found;
    string id;
    string name;
    string authorId;
    string authorName;
    string createdAt;
    string description;
    string imageUrl;
    string releaseStatus;
    string thumbnailImageUrl;
    string updatedAt;
    /// VRChat's own version counter for the world, not a schema version.
    long worldVersion;
    /// When this row was written, as a Unix timestamp. Zero when not found.
    long addedAt;
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
            "INSERT INTO ws_events (received_at, event_type, source, data) VALUES (?, ?, ?, ?)",
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
            "SELECT id, received_at, event_type, data FROM ws_events WHERE id > ? ORDER BY id ASC LIMIT ?",
            afterId.to!string,
            limit.to!string,
        );
    }

    /// Query events before a given ID, newest first (for client back-fill).
    auto queryEventsBefore(long beforeId, int limit = 100)
    {
        logDebugging("queryEventsBefore: beforeId=%d limit=%d", beforeId, limit);
        return db.query(
            "SELECT id, received_at, event_type, data FROM ws_events WHERE id < ? ORDER BY id DESC LIMIT ?",
            beforeId.to!string,
            limit.to!string,
        );
    }

    /// Query recent events (for CLI viewer).
    auto queryRecentEvents(int limit = 50)
    {
        return db.query(
            "SELECT id, received_at, event_type, data FROM ws_events ORDER BY id DESC LIMIT ?",
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

    /// Read a world out of the metadata cache. `found` is false when the world
    /// has never been fetched; freshness is the caller's to judge, since a
    /// stale name still beats showing a raw ID when VRChat cannot be reached.
    CachedWorld getCachedWorld(string worldId)
    {
        CachedWorld world;
        if (worldId.length == 0)
            return world;

        // `added_at` is written by SQLite's own datetime('now') and read back
        // as a Unix timestamp the same way, so the two never have to agree on
        // a text format across the language boundary.
        foreach (row; db.query(
            "SELECT id, CAST(strftime('%s', added_at) AS INTEGER), " ~
            "author_id, author_name, created_at, description, " ~
            "image_url, name, release_status, thumbnail_image_url, updated_at, version " ~
            "FROM cache_world WHERE id = ?",
            worldId,
        ))
        {
            world.found             = true;
            world.id                = row[0];
            string added = row[1];
            if (added.length > 0)
                world.addedAt = added.to!long;
            world.authorId          = row[2];
            world.authorName        = row[3];
            world.createdAt         = row[4];
            world.description       = row[5];
            world.imageUrl          = row[6];
            world.name              = row[7];
            world.releaseStatus     = row[8];
            world.thumbnailImageUrl = row[9];
            world.updatedAt         = row[10];
            string ver = row[11];
            if (ver.length > 0)
                world.worldVersion = ver.to!long;
            logTrace("getCachedWorld: hit %s -> %s", worldId, world.name);
            return world;
        }

        logTrace("getCachedWorld: miss %s", worldId);
        return world;
    }

    /// Write (or refresh) a world in the metadata cache. `added_at` is set to
    /// now, since that is what the row's freshness is measured from.
    void cacheWorld(ref CachedWorld world)
    {
        if (world.id.length == 0)
            return;

        foreach (_; db.query(
            "INSERT INTO cache_world (id, added_at, author_id, author_name, created_at, " ~
            "description, image_url, name, release_status, thumbnail_image_url, " ~
            "updated_at, version) " ~
            "VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " ~
            "ON CONFLICT(id) DO UPDATE SET " ~
            "added_at = excluded.added_at, author_id = excluded.author_id, " ~
            "author_name = excluded.author_name, created_at = excluded.created_at, " ~
            "description = excluded.description, image_url = excluded.image_url, " ~
            "name = excluded.name, release_status = excluded.release_status, " ~
            "thumbnail_image_url = excluded.thumbnail_image_url, " ~
            "updated_at = excluded.updated_at, version = excluded.version",
            world.id,
            world.authorId,
            world.authorName,
            world.createdAt,
            world.description,
            world.imageUrl,
            world.name,
            world.releaseStatus,
            world.thumbnailImageUrl,
            world.updatedAt,
            world.worldVersion.to!string,
        )) {}

        logDebugging("cacheWorld: stored %s -> %s", world.id, world.name);
    }

    /// Read a value from the persistent key-value store.
    /// Returns null if the key is missing.
    string getState(string key)
    {
        foreach (row; db.query(
            "SELECT value FROM server_state WHERE key = ?",
            key,
        ))
            return row[0];
        return null;
    }

    /// Write (or overwrite) a value in the persistent key-value store.
    /// A null or empty value is still stored as such.
    void setState(string key, string value)
    {
        foreach (_; db.query(
            "INSERT INTO server_state (key, value) VALUES (?, ?) " ~
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            key,
            value,
        )) {}
    }

    /// Delete a key from the persistent key-value store.
    void deleteState(string key)
    {
        foreach (_; db.query(
            "DELETE FROM server_state WHERE key = ?",
            key,
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

        // Append-only event log (raw + synthetic).
        // `data` is the JSON event payload: for raw events, the original WS
        // envelope; for synthetic events, a server-built envelope with any
        // extracted fields (e.g. avatar_id on avatar-change).
        db.exec(
            "CREATE TABLE IF NOT EXISTS ws_events (" ~
            "  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
            "  received_at TEXT NOT NULL," ~
            "  event_type TEXT NOT NULL," ~
            "  source TEXT," ~
            "  data TEXT" ~
            ")"
        );

        // Migrations on ws_events.
        bool hasSource;
        bool hasContentJson;
        bool hasData;
        bool hasRawJson;
        foreach (row; db.query("PRAGMA table_info(ws_events)"))
        {
            string name = row[1];
            if (name == "source")       hasSource = true;
            if (name == "content_json") hasContentJson = true;
            if (name == "data")         hasData = true;
            if (name == "raw_json")     hasRawJson = true;
        }
        // Legacy databases have `content_json` instead of `source`.
        // The two columns serve different purposes, but `content_json` was
        // unconditionally NULL in recent versions, so renaming preserves no data
        // worth keeping while avoiding a full table rebuild.
        if (hasSource == false && hasContentJson)
        {
            logInfo("Migrating ws_events: renaming content_json to source");
            db.exec("ALTER TABLE ws_events RENAME COLUMN content_json TO source");
        }
        // `raw_json` is renamed to `data` now that synthetic events also live
        // in this column and "raw" is no longer accurate.
        if (hasData == false && hasRawJson)
        {
            logInfo("Migrating ws_events: renaming raw_json to data");
            db.exec("ALTER TABLE ws_events RENAME COLUMN raw_json TO data");
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

// The world cache round-trip: the columns, the upsert, and `added_at` coming
// back as the Unix timestamp the TTL is measured against.
unittest
{
    import std.file : remove, tempDir;
    import std.path : buildPath;
    import std.datetime.systime : Clock;

    string path = buildPath(tempDir(), "vrcd-cacheworld-test.db");

    // WAL leaves two companions beside the file, and a leftover from a failed
    // run would make the next one start with a world already cached.
    static void scrub(string file)
    {
        import std.file : exists;

        foreach (string suffix; [ "", "-wal", "-shm" ])
            if (exists(file ~ suffix))
                remove(file ~ suffix);
    }

    scrub(path);
    scope(exit) scrub(path);

    Database db = new Database(path);
    scope(exit) db.close();

    assert(db.getCachedWorld("wrld_nope").found == false);

    CachedWorld world;
    world.id                = "wrld_test";
    world.name              = "The Black Cat";
    world.authorId          = "usr_test";
    world.authorName        = "somebody";
    world.createdAt         = "2020-01-01T00:00:00.000Z";
    world.description       = "a bar";
    world.imageUrl          = "https://example.invalid/i.png";
    world.releaseStatus     = "public";
    world.thumbnailImageUrl = "https://example.invalid/t.png";
    world.updatedAt         = "2024-01-01T00:00:00.000Z";
    world.worldVersion      = 42;
    db.cacheWorld(world);

    CachedWorld read = db.getCachedWorld("wrld_test");
    assert(read.found);
    assert(read.id                == world.id);
    assert(read.name              == world.name);
    assert(read.authorId          == world.authorId);
    assert(read.authorName        == world.authorName);
    assert(read.createdAt         == world.createdAt);
    assert(read.description       == world.description);
    assert(read.imageUrl          == world.imageUrl);
    assert(read.releaseStatus     == world.releaseStatus);
    assert(read.thumbnailImageUrl == world.thumbnailImageUrl);
    assert(read.updatedAt         == world.updatedAt);
    assert(read.worldVersion      == 42);

    // datetime('now') is UTC and so is this, within the second or two the
    // insert took.
    long now = Clock.currTime.toUnixTime!long();
    assert(read.addedAt > now - 60 && read.addedAt <= now + 60);

    // A re-fetch replaces the row rather than adding one.
    world.name = "The Black Cat (renamed)";
    db.cacheWorld(world);
    assert(db.getCachedWorld("wrld_test").name == world.name);
    assert(db.getStats().worldCacheCount == 1);
}
