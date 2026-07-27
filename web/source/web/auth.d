/// Shared-secret gate for the web front-end.
///
/// A stopgap, not an identity system: one secret, one cookie, sessions held in
/// memory and lost on restart. It exists so the page and the join endpoint are
/// not simply open to anything that can reach the port.
///
/// WebSockets get a separate mechanism. The upgrade happens inside ddhttpd
/// before our handler runs and `WebSocketConnection` exposes no request
/// headers, so the cookie cannot be read there. Instead the page asks a
/// cookie-authenticated endpoint for a short-lived single-use ticket and puts
/// that in the socket path. A ticket that leaks into a log or a referrer is
/// worthless seconds later, which the secret itself would not be.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.auth;

import core.sync.mutex : Mutex;
import std.datetime : Clock;
import std.string : indexOf, strip;

/// How long a login lasts.
private enum long SESSION_TTL = 12 * 60 * 60;
/// How long a WebSocket ticket stays redeemable. Only has to cover the round
/// trip from fetching it to opening the socket.
private enum long TICKET_TTL = 30;
/// Name of the session cookie.
enum string COOKIE_NAME = "vrcd_session";

/// Session and WebSocket-ticket store.
class SessionStore
{
    this(string secret)
    {
        this.secret = secret;
        this.mutex = new Mutex();
    }

    /// True when no secret is configured, which leaves every route open.
    bool disabled() const
    {
        return secret.length == 0;
    }

    /// Check a submitted secret and issue a session token, or null on refusal.
    string login(string submitted)
    {
        if (constantTimeEquals(submitted, secret) == false)
            return null;

        string token = randomToken();
        synchronized (mutex)
        {
            sweep();
            sessions[token] = now() + SESSION_TTL;
        }
        return token;
    }

    /// True when the token names a live session.
    bool validSession(string token)
    {
        if (disabled)
            return true;
        if (token.length == 0)
            return false;

        synchronized (mutex)
        {
            long *expiry = token in sessions;
            if (expiry is null)
                return false;
            if (*expiry < now())
            {
                sessions.remove(token);
                return false;
            }
            return true;
        }
    }

    /// Issue a single-use WebSocket ticket. Caller must already hold a session.
    string issueTicket()
    {
        string ticket = randomToken();
        synchronized (mutex)
        {
            sweep();
            tickets[ticket] = now() + TICKET_TTL;
        }
        return ticket;
    }

    /// Redeem a WebSocket ticket. Succeeds at most once per ticket.
    bool redeemTicket(string ticket)
    {
        if (disabled)
            return true;
        if (ticket.length == 0)
            return false;

        synchronized (mutex)
        {
            long *expiry = ticket in tickets;
            if (expiry is null)
                return false;
            long deadline = *expiry;
            tickets.remove(ticket);
            return deadline >= now();
        }
    }

private:
    string secret;
    Mutex mutex;
    long[string] sessions;
    long[string] tickets;

    static long now()
    {
        return Clock.currTime.toUnixTime!long();
    }

    /// Drop expired entries. Called under the lock on every issue, which is
    /// often enough for a store this small.
    void sweep()
    {
        long cutoff = now();
        foreach (string key; sessions.keys)
            if (sessions[key] < cutoff)
                sessions.remove(key);
        foreach (string key; tickets.keys)
            if (tickets[key] < cutoff)
                tickets.remove(key);
    }
}

/// Pull the session cookie out of a Cookie header.
string sessionFromCookies(string header)
{
    if (header.length == 0)
        return null;

    string rest = header;
    while (rest.length > 0)
    {
        ptrdiff_t semi = rest.indexOf(';');
        string pair = semi >= 0 ? rest[0 .. semi] : rest;
        rest = semi >= 0 ? rest[semi + 1 .. $] : null;

        pair = pair.strip();
        ptrdiff_t equals = pair.indexOf('=');
        if (equals <= 0)
            continue;
        if (pair[0 .. equals] == COOKIE_NAME)
            return pair[equals + 1 .. $];
    }
    return null;
}

/// Read the value of one field out of an application/x-www-form-urlencoded
/// body. Returns null when the field is absent.
string formField(const(char)[] body_, string field)
{
    import std.uri : decodeComponent, URIException;

    const(char)[] rest = body_;
    while (rest.length > 0)
    {
        ptrdiff_t amp = rest.indexOf('&');
        const(char)[] pair = amp >= 0 ? rest[0 .. amp] : rest;
        rest = amp >= 0 ? rest[amp + 1 .. $] : null;

        ptrdiff_t equals = pair.indexOf('=');
        if (equals <= 0)
            continue;
        if (pair[0 .. equals] != field)
            continue;

        // '+' predates %20 in form encoding and browsers still emit it.
        char[] value = pair[equals + 1 .. $].dup;
        foreach (ref char c; value)
            if (c == '+')
                c = ' ';

        try return decodeComponent(value);
        catch (URIException)
            return null;
    }
    return null;
}

/// Compare two strings without leaking where they first differ. The lengths
/// are not secret, only the contents.
bool constantTimeEquals(const(char)[] a, const(char)[] b)
{
    if (a.length != b.length)
        return false;

    uint diff;
    foreach (size_t i, char c; a)
        diff |= c ^ b[i];
    return diff == 0;
}

/// 128 bits of randomness from the OS, hex encoded.
string randomToken()
{
    ubyte[16] bytes = void;
    osRandom(bytes);

    enum string HEX = "0123456789abcdef";
    char[32] out_ = void;
    foreach (size_t i, ubyte b; bytes)
    {
        out_[i * 2]     = HEX[b >> 4];
        out_[i * 2 + 1] = HEX[b & 0x0F];
    }
    return out_.idup;
}

version (Windows)
{
    // RtlGenRandom. Exported under its original name from advapi32, which is
    // why the pragma does not match the declaration.
    private extern (Windows) ubyte SystemFunction036(void *buffer, uint length) @nogc nothrow;
    pragma(lib, "advapi32");

    private void osRandom(ref ubyte[16] buffer)
    {
        if (SystemFunction036(buffer.ptr, buffer.length) == 0)
            throw new Exception("RtlGenRandom failed");
    }
}
else
{
    private void osRandom(ref ubyte[16] buffer)
    {
        import std.stdio : File;

        File source = File("/dev/urandom", "rb");
        scope(exit) source.close();
        ubyte[] read = source.rawRead(buffer[]);
        if (read.length != buffer.length)
            throw new Exception("Short read from /dev/urandom");
    }
}

unittest
{
    assert(sessionFromCookies("vrcd_session=abc") == "abc");
    assert(sessionFromCookies("other=1; vrcd_session=abc; more=2") == "abc");
    // A cookie whose name merely ends with ours must not match.
    assert(sessionFromCookies("not_vrcd_session=abc") is null);
    assert(sessionFromCookies("") is null);

    assert(formField("secret=hunter2", "secret") == "hunter2");
    assert(formField("a=1&secret=hu%40nter+2&b=3", "secret") == "hu@nter 2");
    assert(formField("a=1", "secret") is null);

    assert(constantTimeEquals("abc", "abc"));
    assert(constantTimeEquals("abc", "abd") == false);
    assert(constantTimeEquals("abc", "ab") == false);

    assert(randomToken().length == 32);
    assert(randomToken() != randomToken());

    SessionStore store = new SessionStore("s3cret");
    assert(store.disabled == false);
    assert(store.login("wrong") is null);
    string token = store.login("s3cret");
    assert(token.length == 32);
    assert(store.validSession(token));
    assert(store.validSession("nope") == false);

    string ticket = store.issueTicket();
    assert(store.redeemTicket(ticket));
    // Single use.
    assert(store.redeemTicket(ticket) == false);

    // With no secret configured everything is permitted.
    SessionStore open = new SessionStore("");
    assert(open.disabled);
    assert(open.validSession(""));
    assert(open.redeemTicket(""));
}
