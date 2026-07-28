/// vrcd web front-end.
///
/// Serves the online roster and the event feed over HTTP, reading state from
/// vrcd-server over the JSON-L API.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module app;

import core.thread : Thread;
import core.time : dur;
import std.conv : ConvException, to;
import std.getopt;
import std.json;
import std.stdio;
import std.string : lastIndexOf, strip, toStringz;

import ddhttpd;
import ddlogger;

import web.assets;
import web.auth;
import web.connection;
import web.hub;
import web.images;
import web.state;

/// Web front-end version.
immutable string VERSION = import("VERSION");

/// Largest request body accepted, which in practice means the largest upload:
/// VRChat's 10 MB picture, plus base64 expansion and the JSON around it.
private enum size_t UPLOAD_MAX_BYTES = 16 * 1024 * 1024;

int main(string[] args)
{
    string listenAddr = "127.0.0.1";
    ushort listenPort = 8080;
    string serverHost = "127.0.0.1";
    ushort serverPort = 9700;
    string secret;
    string webSecret;
    string webRoot;
    string imageCache;
    bool noImageCache;
    bool verbose;
    bool showVersion;

    GetoptResult opts = void;
    try opts = getopt(args,
        std.getopt.config.caseSensitive,
        "listen|l",  "Address to serve HTTP on (default: 127.0.0.1:8080)",
            (string _, string value) {
                parseHostPort(value, listenAddr, listenPort);
            },
        "server|s",  "vrcd-server address as host:port (default: 127.0.0.1:9700)",
            (string _, string value) {
                parseHostPort(value, serverHost, serverPort);
            },
        "secret",    "Shared secret for vrcd-server auth", &secret,
        "web-secret", "Shared secret browsers must present to sign in", &webSecret,
        "web-root",  "Directory holding the front-end files (default: public/ beside the binary)", &webRoot,
        "image-cache", "vrcd-server's image cache directory, when it shares this host", &imageCache,
        "no-image-cache", "Never read vrcd-server's image cache, even on one host", &noImageCache,
        "verbose|v", "Enable verbose logging", &verbose,
        "version",   "Show version and exit", &showVersion,
    );
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }

    if (opts.helpWanted)
    {
        defaultGetoptPrinter("vrcd web front-end", opts.options);
        return 0;
    }

    if (showVersion)
    {
        writeln(strip(VERSION));
        return 0;
    }

    ConsoleAppender appender = new ConsoleAppender();
    appender.setLogLevel(verbose ? LogLevel.trace : LogLevel.info);
    logAddAppender(appender);

    // Resolved before anything else starts: the front-end is on disk, so a
    // missing document root is a startup error rather than a broken page.
    webRoot = findWebRoot(webRoot);
    if (webRoot is null)
        return 1;

    AssetStore assets = new AssetStore(webRoot);
    logInfo("Serving front-end from %s", webRoot);

    SessionStore sessions = new SessionStore(webSecret);
    if (sessions.disabled)
        logWarn("No --web-secret set: every route is open to anyone who can " ~
            "reach %s:%u", listenAddr, listenPort);

    ServerLink link = new ServerLink(serverHost, serverPort, secret);

    // A shortcut for images vrcd-server has already downloaded, when it is on
    // this host. Everything still works without it, only slower: a miss goes
    // down the link the same as before.
    if (noImageCache == false)
        link.setImageCacheDir(findServerImageCache(imageCache));

    Hub hub = new Hub();

    // Every state change on the link becomes one broadcast. Publish once up
    // front so a browser connecting before the link is up still gets a
    // snapshot (showing the disconnected state) rather than a blank page.
    link.setChangeCallback(() { hub.publishState(buildStateJSON(link)); });
    link.setFeedCallback((FeedEntry[] entries, bool reset) {
        string[] encoded;
        encoded.reserve(entries.length);
        foreach (ref FeedEntry entry; entries)
            encoded ~= encodeFeedEntry(entry);
        hub.publishFeed(encoded, reset);
    });
    hub.publishState(buildStateJSON(link));
    link.start();

    /// True when the request carries a live session. Replies for itself when
    /// it does not, so handlers can simply return after a false.
    bool authorized(ref HTTPRequest req, bool isApi)
    {
        if (sessions.validSession(sessionFromCookies(req.header("Cookie"))))
            return true;

        if (isApi)
            req.replyJSON(401, `{"error":"not signed in"}`);
        else
            req.redirect(303, "/login");
        return false;
    }

    /// Reply with a file from the web root, or 404 when it is not there.
    void serveAsset(ref HTTPRequest req, string name)
    {
        Asset asset = assets.get(name);
        if (asset.found == false)
        {
            req.reply(HTTPStatus.notFound,
                HTTPReply.copyBuffer(HTTPMsg.notFound), ContentType.text_plain.ptr);
            return;
        }

        // The store re-reads a file as soon as its mtime moves, so let the
        // browser revalidate rather than sit on an edited stylesheet.
        req.addHeader("Cache-Control", "no-cache");
        req.reply(HTTPStatus.ok, HTTPReply.copyBuffer(asset.content), asset.contentType);
    }

    HTTPServer http = new HTTPServer()
        // Uploads are the only large bodies here. VRChat caps a picture at
        // 10 MB, base64 adds a third, and the JSON around it is noise; past
        // that a body is either a mistake or someone filling our memory.
        .maxUploadSize(UPLOAD_MAX_BYTES)
        .get(`/`, (ref HTTPRequest req)
        {
            if (authorized(req, false) == false)
                return REQUEST_OK;

            serveAsset(req, "index.html");
            return REQUEST_OK;
        })
        .get(`/login`, (ref HTTPRequest req)
        {
            serveAsset(req, "login.html");
            return REQUEST_OK;
        })
        // Left open: the stylesheets and scripts carry no state, and the login
        // page needs its own before there is a session to check.
        .get(`/static/:name`, (ref HTTPRequest req)
        {
            string *name = "name" in req.params;
            if (name is null)
            {
                req.reply(HTTPStatus.notFound,
                    HTTPReply.copyBuffer(HTTPMsg.notFound), ContentType.text_plain.ptr);
                return REQUEST_OK;
            }

            serveAsset(req, *name);
            return REQUEST_OK;
        })
        // Both live at the root rather than under /static/ because their paths
        // are load-bearing: a worker's scope is the directory it was served
        // from, so /static/sw.js could only ever control /static/, and the
        // manifest is fetched without cookies, which puts it outside a session
        // check either way. Same open reasoning as /static/: neither carries
        // state, and the install prompt has to work before signing in.
        .get(`/sw.js`, (ref HTTPRequest req)
        {
            serveAsset(req, "sw.js");
            return REQUEST_OK;
        })
        .get(`/manifest.webmanifest`, (ref HTTPRequest req)
        {
            serveAsset(req, "manifest.webmanifest");
            return REQUEST_OK;
        })
        .post(`/login`, (ref HTTPRequest req)
        {
            string token = sessions.login(formField(cast(const(char)[])req.payload, "secret"));
            if (token.length == 0)
            {
                logWarn("Rejected sign-in attempt");
                req.redirect(303, "/login?bad");
                return REQUEST_OK;
            }

            // HttpOnly keeps the token out of reach of page scripts; SameSite
            // strict means another site cannot ride the session.
            req.addHeader("Set-Cookie", toStringz(
                COOKIE_NAME ~ "=" ~ token ~
                "; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200"));
            req.redirect(303, "/");
            return REQUEST_OK;
        })
        .get(`/api/state`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            req.replyJSON(HTTPStatus.ok, buildStateJSON(link));
            return REQUEST_OK;
        })
        .get(`/api/wsticket`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            req.replyJSON(HTTPStatus.ok, `{"ticket":"` ~ sessions.issueTicket() ~ `"}`);
            return REQUEST_OK;
        })
        .post(`/api/join`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            string location = joinLocation(req.payload);
            if (location.length == 0)
            {
                req.replyJSON(HTTPStatus.badRequest, `{"error":"missing location"}`);
                return REQUEST_OK;
            }

            // Fire and forget: the outcome arrives as a join_instance_result
            // and reaches the page through the next broadcast.
            link.requestJoin(location);
            req.replyJSON(HTTPStatus.ok, `{"requested":true}`);
            return REQUEST_OK;
        })
        .post(`/api/notification`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            string id, action;
            if (notificationAction(req.payload, id, action) == false)
            {
                req.replyJSON(HTTPStatus.badRequest,
                    `{"error":"missing notification_id or action"}`);
                return REQUEST_OK;
            }

            // Fire and forget, like /api/join: the outcome arrives as a
            // notification_action_result and reaches the page in the next
            // broadcast, which also drops the row.
            link.requestNotificationAction(id, action);
            req.replyJSON(HTTPStatus.ok, `{"requested":true}`);
            return REQUEST_OK;
        })
        .get(`/api/content/:section`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            string *section = "section" in req.params;
            if (section is null || contentSectionIndex(*section) < 0)
            {
                req.replyJSON(HTTPStatus.badRequest, `{"error":"unknown section"}`);
                return REQUEST_OK;
            }

            // A first look starts the fetch and comes back with `loading`, so
            // the page has something to draw while vrcd-server asks VRChat.
            // `refresh=1` is the section's reload button, `more=1` its next
            // page.
            if (req.param("more") == "1")
                link.requestMoreContent(*section);
            else
                link.requestContent(*section, req.param("refresh") == "1");

            req.replyJSON(HTTPStatus.ok, buildContentJSON(link, *section));
            return REQUEST_OK;
        })
        .post(`/api/content`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            string action, id, slot;
            if (contentAction(req.payload, action, id, slot) == false)
            {
                req.replyJSON(HTTPStatus.badRequest,
                    `{"error":"bad content action"}`);
                return REQUEST_OK;
            }

            // Fire and forget, like /api/join: the outcome arrives as the
            // matching result message, which also re-lists what it changed.
            if (action == "equip" || action == "unequip" || action == "consume")
                link.requestInventoryAction(action, id, slot);
            else
                link.requestContentAction(action, id);

            req.replyJSON(HTTPStatus.ok, `{"requested":true}`);
            return REQUEST_OK;
        })
        .post(`/api/upload`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            string tag, data, note;
            if (uploadRequest(req.payload, tag, data, note) == false)
            {
                req.replyJSON(HTTPStatus.badRequest, `{"error":"bad upload"}`);
                return REQUEST_OK;
            }

            // The picture itself is only checked by vrcd-server, which is the
            // side that knows VRChat's rules (PNG, dimensions, square for
            // stickers and emoji) and has to answer for them anyway.
            link.requestUpload(tag, data, note);
            req.replyJSON(HTTPStatus.ok, `{"requested":true}`);
            return REQUEST_OK;
        })
        .get(`/api/image/:file_id`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            string *fileId = "file_id" in req.params;
            if (fileId is null || isFileId(*fileId) == false)
            {
                req.replyJSON(HTTPStatus.badRequest, `{"error":"bad file id"}`);
                return REQUEST_OK;
            }

            long fileVersion = imageNumber(req.param("v"), 1);
            int size = cast(int)imageNumber(req.param("size"), 0);
            if (fileVersion < 1 || isThumbnailSize(size) == false)
            {
                req.replyJSON(HTTPStatus.badRequest,
                    `{"error":"bad version or size"}`);
                return REQUEST_OK;
            }

            ImageLookup found = link.image(*fileId, fileVersion, size);
            final switch (found.state) with (ImageState)
            {
            case ready:
                // Content at a given file, version and size never changes, so
                // the browser can keep it for as long as it likes.
                req.addHeader("Cache-Control", "private, max-age=86400, immutable");
                req.reply(HTTPStatus.ok, HTTPReply.copyBuffer(found.data),
                    toStringz(found.mimeType));
                break;

            case pending:
                // 202: it is on its way down the link. The page comes back for
                // it rather than this handler blocking, which in ddhttpd would
                // stall every other request on the same poll thread.
                req.replyJSON(202, `{"pending":true}`);
                break;

            case failed:
                req.replyJSON(502,
                    JSONValue([ "error": JSONValue(found.error) ]).toString());
                break;
            }
            return REQUEST_OK;
        })
        .post(`/api/auth`, (ref HTTPRequest req)
        {
            if (authorized(req, true) == false)
                return REQUEST_OK;

            AuthAnswer answer;
            if (parseAuthAnswer(req.payload, answer) == false)
            {
                req.replyJSON(HTTPStatus.badRequest, `{"error":"bad sign-in answer"}`);
                return REQUEST_OK;
            }

            // Not fire and forget, unlike the two above: there is no result
            // message for a sign-in, so whether the answer reached the link is
            // the only thing the page can be told.
            bool sent;
            switch (answer.action)
            {
            case "credentials": sent = link.submitCredentials(answer.username, answer.password); break;
            case "two_factor":  sent = link.submitTwoFactor(answer.code); break;
            default:            sent = link.cancelAuth(); break; // "cancel"; nothing else parses.
            }

            if (sent == false)
            {
                // 503, spelled as a number: ddhttpd's HTTPStatus stops at 413.
                req.replyJSON(503, `{"error":"not connected to vrcd-server"}`);
                return REQUEST_OK;
            }

            req.replyJSON(HTTPStatus.ok, `{"sent":true}`);
            return REQUEST_OK;
        })
        .websocket(`/ws/:ticket`, (WebSocketConnection conn)
        {
            // The cookie cannot be read after ddhttpd has upgraded the
            // connection, so the page trades it for a single-use ticket first.
            string *ticket = "ticket" in conn.params;
            if (ticket is null || sessions.redeemTicket(*ticket) == false)
            {
                logWarn("Rejected WebSocket with a bad ticket");
                conn.close(1008, "unauthorized");
                return;
            }

            hub.serve(conn);
        })
    ;

    try http.start(listenAddr, listenPort);
    catch (Exception ex)
    {
        logError("Could not serve on %s:%u: %s", listenAddr, listenPort, ex.msg);
        return 1;
    }

    logInfo("Listening on http://%s:%u", listenAddr, listenPort);

    // MHD serves from its own polling thread, so park the main thread.
    while (true)
        Thread.sleep(dur!"hours"(1));
}

/// Pull the location out of a /api/join request body. Returns null when the
/// body is not an object with a non-empty "location" string.
private string joinLocation(ubyte[] payload)
{
    if (payload.length == 0)
        return null;

    JSONValue body_;
    try body_ = parseJSON(cast(const(char)[])payload);
    catch (JSONException ex)
    {
        logWarn("Malformed join request: %s", ex.msg);
        return null;
    }

    if (body_.type != JSONType.object)
        return null;
    if (const(JSONValue) *v = "location" in body_)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}

/// Pull the notification ID and action out of a /api/notification request
/// body. Returns false when either is missing or the action is not one the
/// server takes, so an unknown action is refused here rather than travelling
/// down to vrcd-server to be refused there.
private bool notificationAction(ubyte[] payload, out string id, out string action)
{
    if (payload.length == 0)
        return false;

    JSONValue body_;
    try body_ = parseJSON(cast(const(char)[])payload);
    catch (JSONException ex)
    {
        logWarn("Malformed notification request: %s", ex.msg);
        return false;
    }

    if (body_.type != JSONType.object)
        return false;

    if (const(JSONValue) *v = "notification_id" in body_)
        if (v.type == JSONType.string)
            id = v.str;
    if (const(JSONValue) *v = "action" in body_)
        if (v.type == JSONType.string)
            action = v.str;

    if (id.length == 0)
        return false;
    return action == "accept" || action == "hide";
}

/// Pull a content action out of a /api/content request body. Returns false
/// when the action is not one this front-end offers, or when the fields that
/// action needs are missing. vrcd-server checks these again (it is the one
/// talking to VRChat), but a typo is worth refusing before it costs a round
/// trip.
private bool contentAction(ubyte[] payload, out string action, out string id,
    out string slot)
{
    if (payload.length == 0)
        return false;

    JSONValue body_;
    try body_ = parseJSON(cast(const(char)[])payload);
    catch (JSONException ex)
    {
        logWarn("Malformed content request: %s", ex.msg);
        return false;
    }

    if (body_.type != JSONType.object)
        return false;

    if (const(JSONValue) *v = "action" in body_)
        if (v.type == JSONType.string)
            action = v.str;
    if (const(JSONValue) *v = "id" in body_)
        if (v.type == JSONType.string)
            id = v.str;
    if (const(JSONValue) *v = "slot" in body_)
        if (v.type == JSONType.string)
            slot = v.str;

    switch (action)
    {
    // Unequip addresses the slot rather than the item, so the ID is optional
    // there and required for the rest.
    case "equip":                        return id.length > 0 && slot.length > 0;
    case "unequip":                      return slot.length > 0;
    case "consume", "delete_file",
         "delete_print":                 return id.length > 0;
    // An empty ID is how the profile icon is cleared, so this one takes it.
    case "set_icon":                     return true;
    default:                             return false;
    }
}

/// Pull an upload out of a /api/upload request body. The picture itself is
/// only looked at by vrcd-server: it knows VRChat's rules and has to answer
/// for them anyway.
private bool uploadRequest(ubyte[] payload, out string tag, out string data,
    out string note)
{
    if (payload.length == 0)
        return false;

    JSONValue body_;
    try body_ = parseJSON(cast(const(char)[])payload);
    catch (JSONException ex)
    {
        logWarn("Malformed upload request: %s", ex.msg);
        return false;
    }

    if (body_.type != JSONType.object)
        return false;

    if (const(JSONValue) *v = "tag" in body_)
        if (v.type == JSONType.string)
            tag = v.str;
    if (const(JSONValue) *v = "data_base64" in body_)
        if (v.type == JSONType.string)
            data = v.str;
    if (const(JSONValue) *v = "note" in body_)
        if (v.type == JSONType.string)
            note = v.str;

    if (data.length == 0)
        return false;

    switch (tag)
    {
    case "gallery", "icon", "sticker", "emoji", "print": return true;
    default:                                            return false;
    }
}

/// Whether this looks like a VRChat file ID. The value lands in a path
/// vrcd-server builds, so anything else is refused here.
private bool isFileId(string value)
{
    import std.ascii : isAlphaNum;

    if (value.length <= 5 || value.length > 64)
        return false;
    if (value[0 .. 5] != "file_")
        return false;

    foreach (char c; value[5 .. $])
    {
        if (isAlphaNum(c) == false && c != '-' && c != '_')
            return false;
    }
    return true;
}

/// One of the thumbnail edges VRChat serves, or 0 for the original file.
private bool isThumbnailSize(long size)
{
    switch (size)
    {
    case 0, 128, 256, 512, 1024: return true;
    default:                     return false;
    }
}

/// Read a query argument as a number, falling back when it is absent or not
/// one. A negative answer is left to the caller to refuse.
private long imageNumber(string value, long fallback)
{
    if (value.length == 0)
        return fallback;

    try return value.to!long();
    catch (ConvException)
        return -1;
}

/// One answer to the VRChat sign-in prompt vrcd-server delegates to us.
private struct AuthAnswer
{
    /// "credentials", "two_factor", or "cancel".
    string action;
    string username;
    string password;
    string code;
}

/// Pull a sign-in answer out of a /api/auth request body. Returns false when
/// the action is not one of the three, or when the fields that action needs
/// are missing: a blank password is worth refusing here rather than spending
/// one of VRChat's login attempts on it.
///
/// Nothing here is logged. The body carries a VRChat password.
private bool parseAuthAnswer(ubyte[] payload, out AuthAnswer answer)
{
    if (payload.length == 0)
        return false;

    JSONValue body_;
    try body_ = parseJSON(cast(const(char)[])payload);
    catch (JSONException)
    {
        logWarn("Malformed sign-in answer");
        return false;
    }

    if (body_.type != JSONType.object)
        return false;

    if (const(JSONValue) *v = "action" in body_)
        if (v.type == JSONType.string)
            answer.action = v.str;
    if (const(JSONValue) *v = "username" in body_)
        if (v.type == JSONType.string)
            answer.username = v.str;
    if (const(JSONValue) *v = "password" in body_)
        if (v.type == JSONType.string)
            answer.password = v.str;
    if (const(JSONValue) *v = "code" in body_)
        if (v.type == JSONType.string)
            answer.code = v.str;

    switch (answer.action)
    {
    case "credentials": return answer.username.length > 0 && answer.password.length > 0;
    case "two_factor":  return answer.code.length > 0;
    case "cancel":      return true;
    default:            return false;
    }
}

/// Split a "host:port" argument. A bare host leaves the port untouched.
/// Note this takes the last colon, so bare IPv6 literals need brackets.
private void parseHostPort(string value, ref string host, ref ushort port)
{
    ptrdiff_t colon = value.lastIndexOf(':');
    if (colon < 0)
    {
        host = value;
        return;
    }

    host = value[0 .. colon];
    port = value[colon + 1 .. $].to!ushort();
}
