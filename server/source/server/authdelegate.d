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
        if (broadcastFn)
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

        logDebugging("submitResponse: cancelled=%s usernameLen=%d codeLen=%d",
            resp.cancelled, resp.username.length, resp.code.length);
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

/// One-way pair-request delegator for the Drop-a-Portal companion.
///
/// Unlike `AuthDelegator`, the server doesn't need a structured response
/// payload: pairing is the RFC 8628 device-code flow and the server polls
/// dropaport.al directly. The delegator's job is to surface the user code
/// and verification URL to a connected client so the user can approve it
/// in a browser, and to signal cancellation if the user clicks "Cancel".
class DropaPortalDelegator
{
    /// Active pair-request to replay to clients that connect mid-flow.
    private Mutex mtx;
    private bool active;
    private JSONValue pendingMsg;
    private bool cancelled;
    private void delegate(JSONValue) broadcastFn;
    /// Current paired-account name. Empty when not paired. Held outside the
    /// active/pendingMsg pair-flow state so a fresh client connection can
    /// learn the standing pair status without re-triggering the pair UI.
    private string pairedUsername;

    this()
    {
        mtx = new Mutex();
    }

    /// Set the callback used to broadcast `dap_pair_request` / status
    /// updates to connected clients.
    void setBroadcastCallback(void delegate(JSONValue) fn)
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        broadcastFn = fn;
    }

    /// Begin a pair flow. Broadcasts the user-code / URL to clients and
    /// stores the message so clients connecting mid-flow can be brought
    /// up to speed via `getPendingRequestMessage`.
    void beginPairing(string userCode, string verificationUri, long expiresIn, long pollInterval)
    {
        JSONValue msg = JSONValue([
            "type": JSONValue("dap_pair_request"),
            "user_code": JSONValue(userCode),
            "verification_uri": JSONValue(verificationUri),
            "expires_in": JSONValue(expiresIn),
            "interval": JSONValue(pollInterval),
        ]);

        mtx.lock();
        active = true;
        cancelled = false;
        pendingMsg = msg;
        void delegate(JSONValue) fn = broadcastFn;
        mtx.unlock();

        logInfo("DropaPortal: broadcasting pair request (code=%s)", userCode);
        if (fn)
            fn(msg);
    }

    /// Broadcast a terminal status update (paired / error / login_error) and
    /// clear the active pair flow. The `type` field of `msg` should already
    /// be set to one of `dap_pair_complete`, `dap_pair_error`, `dap_login_error`.
    void endPairing(JSONValue msg)
    {
        mtx.lock();
        active = false;
        cancelled = false;
        pendingMsg = JSONValue(null);
        void delegate(JSONValue) fn = broadcastFn;
        mtx.unlock();

        if (fn)
            fn(msg);
    }

    /// Mark the active pair flow as cancelled by a client. The pairing thread
    /// polls `wasCancelled` between auth/poll attempts.
    void cancel()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        if (active == false)
        {
            logDebugging("DropaPortalDelegator.cancel: no active pair flow, ignoring");
            return;
        }
        cancelled = true;
        logInfo("DropaPortal: pairing cancelled by client");
    }

    /// True if a `cancel()` call landed since the current pair flow began.
    bool wasCancelled()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        return cancelled;
    }

    /// Non-blocking check for an active pair flow. Used when a new client connects.
    bool hasPendingRequest()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        return active;
    }

    /// Returns the pending pair-request message as JSON. Call only if
    /// `hasPendingRequest()` is true.
    JSONValue getPendingRequestMessage()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        if (active == false)
            return JSONValue(null);
        return pendingMsg;
    }

    /// Record the standing pair status. Does NOT broadcast; this is set by
    /// the sidecar after each successful token-check so connecting clients
    /// can be told the current state via `getPairStatusMessage`.
    void setPairedUsername(string username)
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        pairedUsername = username;
    }

    /// Returns a `dap_status` snapshot for a freshly-connected client.
    /// Always reports the standing state (paired true/false) so the client
    /// can leave its initial "unknown" state and enable the pairing UI; an
    /// unpaired server must say so explicitly rather than stay silent.
    /// Distinct from `dap_pair_complete` so the client treats it as state,
    /// not a live event (no feed entry).
    JSONValue getPairStatusMessage()
    {
        mtx.lock();
        scope(exit) mtx.unlock();
        if (pairedUsername.length == 0)
            return JSONValue([
                "type":   JSONValue("dap_status"),
                "paired": JSONValue(false),
            ]);
        return JSONValue([
            "type":     JSONValue("dap_status"),
            "paired":   JSONValue(true),
            "username": JSONValue(pairedUsername),
        ]);
    }
}
