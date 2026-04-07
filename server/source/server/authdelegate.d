/// Auth delegation for headless operation.
///
/// When the server runs without a TTY, credential and 2FA prompts are
/// delegated to a connected client via the JSON-L protocol. This module
/// provides the synchronization hub between the auth thread (which
/// blocks waiting for input) and the API server (which communicates
/// with clients).
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.authdelegate;

import core.sync.condition;
import core.sync.mutex;
import core.time : Duration, dur, MonoTime;

import std.json;

import ddlogger;

enum AuthRequestKind
{
    credentials,
    twoFactor,
}

struct AuthRequest
{
    AuthRequestKind kind;
    string twoFactorMethod; /// "totp", "otp", or "emailOtp" (only for twoFactor).
    string error;           /// Non-empty on retry (e.g., "Invalid code, try again").
}

struct AuthResponse
{
    string username;
    string password;
    string code;
    bool cancelled;
}

/// Synchronization hub for delegating auth prompts to connected clients.
///
/// The auth thread calls `requestFromClient()` which blocks until a client
/// responds or the timeout expires. The API server broadcasts the request
/// to clients and forwards their response via `submitResponse()`.
class AuthDelegator
{
    private Mutex mtx;
    private Condition cond;
    private AuthRequest* pending;   /// Non-null when waiting for a response.
    private AuthResponse* response; /// Non-null when a client has responded.
    private void delegate(JSONValue) broadcastFn;

    static immutable Duration timeout = dur!"minutes"(30);

    this()
    {
        mtx = new Mutex();
        cond = new Condition(mtx);
    }

    /// Set the callback used to broadcast auth_request to connected clients.
    void setBroadcastCallback(void delegate(JSONValue) fn)
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        broadcastFn = fn;
    }

    /// Called by the auth thread. Blocks until a client responds or timeout.
    /// Returns the client's response. If timeout or cancelled, response.cancelled is true.
    AuthResponse requestFromClient(AuthRequest req)
    {
        mtx.lock();
        scope(exit) mtx.unlock();

        // Set pending request.
        pending = new AuthRequest(req.kind, req.twoFactorMethod, req.error);
        response = null;

        // Broadcast to connected clients.
        if (broadcastFn !is null)
        {
            JSONValue msg = buildAuthRequestMessage(req);
            broadcastFn(msg);
        }

        logInfo("Waiting for client to provide %s (timeout: 30 minutes)...",
            req.kind == AuthRequestKind.credentials ? "credentials" : "2FA code");

        // Wait for response with timeout.
        MonoTime deadline = MonoTime.currTime + timeout;
        while (response is null)
        {
            Duration remaining = deadline - MonoTime.currTime;
            if (remaining <= Duration.zero)
            {
                logError("Auth delegation timed out after 30 minutes");
                pending = null;
                AuthResponse timedOut;
                timedOut.cancelled = true;
                return timedOut;
            }
            cond.wait(remaining);
        }

        AuthResponse result = *response;
        pending = null;
        response = null;
        return result;
    }

    /// Called by the API server when a client sends auth_response.
    void submitResponse(AuthResponse resp)
    {
        mtx.lock();
        scope(exit) mtx.unlock();

        if (pending is null)
        {
            logWarn("Received auth_response but no pending request, ignoring");
            return;
        }

        response = new AuthResponse(resp.username, resp.password, resp.code, resp.cancelled);
        cond.notify();
    }

    /// Non-blocking check for a pending request. Used when a new client connects.
    bool hasPendingRequest()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        return pending !is null;
    }

    /// Returns the pending request message as JSON. Call only if hasPendingRequest() is true.
    JSONValue getPendingRequestMessage()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        if (pending is null)
            return JSONValue(null);
        return buildAuthRequestMessage(*pending);
    }

    private static JSONValue buildAuthRequestMessage(AuthRequest req)
    {
        JSONValue msg = JSONValue([
            "type": JSONValue("auth_request"),
            "kind": JSONValue(req.kind == AuthRequestKind.credentials ? "credentials" : "two_factor"),
        ]);
        if (req.kind == AuthRequestKind.twoFactor)
            msg["method"] = JSONValue(req.twoFactorMethod);
        if (req.error.length > 0)
            msg["error"] = JSONValue(req.error);
        return msg;
    }
}
