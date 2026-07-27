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
import std.conv : to;
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
import web.state;

/// Web front-end version.
immutable string VERSION = import("VERSION");

int main(string[] args)
{
    string listenAddr = "127.0.0.1";
    ushort listenPort = 8080;
    string serverHost = "127.0.0.1";
    ushort serverPort = 9700;
    string secret;
    string webSecret;
    string webRoot;
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
