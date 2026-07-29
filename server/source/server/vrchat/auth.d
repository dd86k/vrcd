/// VRChat authentication
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.vrchat.auth;

import std.base64;
import std.conv : text;
import std.file : exists, readText, mkdirRecurse;
import std.json;
import std.path : dirName;
import std.stdio : stdin, stderr, write, writeln, readln;
import std.string : strip;
import std.uri : encodeComponent;

import ddlogger;
import ddcurl;

import server.authdelegate;
import server.config;
import server.userimage : UserImage, pickUserImage;
import server.vrchat.totp : generateTOTP;
import server.vrchat.vrcconfig : USER_AGENT;

/// Persisted auth state.
struct AuthState
{
    string authToken; /// WebSocket auth token.
    string userId;    /// Current user ID (usr_...).
    string displayName;
    string currentAvatar; /// Self avatar ID at login (avtr_...).
    string status;            /// Self status ("active", "join me", "ask me", "busy").
    string statusDescription; /// Self custom status message.
    string bio;               /// Self long-form profile blurb.
    string pronouns;          /// Self pronouns.
    string[] bioLinks;        /// Self profile URLs.
    UserImage picture;        /// Self profile picture, as a file to fetch.
}

/// Authenticate with VRChat and obtain a WebSocket token.
///
/// Uses cookie jar for session persistence. If cookies are still valid,
/// skips login. Otherwise performs full login + optional 2FA.
///
/// When `delegator` is non-null, interactive prompts are delegated to
/// a connected client instead of reading from stdin.
AuthState authenticate(ref Config config, HTTPClient client, AuthDelegator delegator = null)
{
    setupClient(client, config);

    // Try existing session first.
    logInfo("Checking existing session...");
    HTTPResponse userResp = client.get("/auth/user");
    logDebugging("GET /auth/user -> HTTP %d (bodyLen=%d)", userResp.code, userResp.text.length);

    if (userResp.code == 200)
    {
        JSONValue userJson = parseJSON(userResp.text);
        if (const(JSONValue) *jrequiresTwoFactorAuth = "requiresTwoFactorAuth" in userJson)
        {
            // 2FA required even with existing cookies.
            handle2FA(config, client, delegator, jrequiresTwoFactorAuth);
            return reAuthUser(client);
        }
        string displayName;
        if (const(JSONValue)* v = "displayName" in userJson)
            displayName = v.str;
        logInfo("Session valid, logged in as %s", displayName);
        return finishAuth(client, userJson);
    }

    // No valid session, do full login.
    return fullLogin(config, client, delegator);
}

/// Interactive login flow (for `auth` subcommand).
AuthState interactiveLogin(ref Config config, HTTPClient client)
{
    setupClient(client, config);
    return fullLogin(config, client, null);
}

/// POST a JSON body to the VRChat API.
///
/// Sets `Content-Type: application/json` for this request only, so the shared
/// client holds no body content type at rest. A multipart upload on the same
/// client is then not tainted by a lingering JSON header (VRChat would reject
/// the body with "JSON failed to parse."). Call under the API mutex, since it
/// mutates the client's header set.
HTTPResponse postJSON(HTTPClient client, string path, string payload)
{
    client.addHeader("Content-Type", "application/json");
    scope(exit) client.removeHeader("Content-Type");
    return client.post(path, payload);
}

/// PUT a JSON body to the VRChat API. See postJSON.
HTTPResponse putJSON(HTTPClient client, string path, string payload = null)
{
    client.addHeader("Content-Type", "application/json");
    scope(exit) client.removeHeader("Content-Type");
    return client.put(path, payload);
}

/// Returns true if stdin is not a terminal (server running as a service).
bool isHeadless()
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;
        import core.stdc.stdio : fileno;
        return isatty(fileno(stdin.getFP())) == 0;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetStdHandle, STD_INPUT_HANDLE;
        import core.sys.windows.wincon : GetConsoleMode;
        auto handle = GetStdHandle(STD_INPUT_HANDLE);
        uint mode;
        return GetConsoleMode(handle, &mode) == 0;
    }
    else
        return false;
}

private:

void setupClient(HTTPClient client, ref Config config)
{
    client.setBaseUrl("https://api.vrchat.cloud/api/1");
    client.setUserAgent(USER_AGENT);

    // Ensure cookie jar directory exists.
    string cookiePath = config.cookieJarPath;
    string dir = dirName(cookiePath);
    if (exists(dir) == false)
        mkdirRecurse(dir);
    client.setCookieJar(cookiePath);
}

AuthState fullLogin(ref Config config, HTTPClient client, AuthDelegator delegator)
{
    // Read credentials.
    string username, password;
    if (exists(config.credentialsPath))
    {
        logInfo("Reading credentials from %s", config.credentialsPath);
        JSONValue creds = parseJSON(readText(config.credentialsPath));
        if (const(JSONValue)* v = "username" in creds)
            username = v.str;
        if (const(JSONValue)* v = "password" in creds)
            password = v.str;
    }
    else if (delegator)
    {
        logInfo("No credentials file found. Requesting credentials from client...");
        AuthResponse resp = delegator.requestFromClient(
            AuthRequest(AuthRequestKind.credentials));
        if (resp.cancelled)
            throw new Exception("Auth delegation timed out or was cancelled");
        username = resp.username;
        password = resp.password;
        saveCredentials(config.credentialsPath, username, password);
    }
    else
    {
        logInfo("No credentials file found. Enter credentials interactively.");
        stderr.write("Username: ");
        username = readln().strip();
        stderr.write("Password: ");
        password = readln().strip();

        // Save credentials for future use.
        saveCredentials(config.credentialsPath, username, password);
    }

    // Step 1: GET config (validate API).
    logInfo("Fetching API config...");
    HTTPResponse configResp = client.get("/config");
    logDebugging("GET /config -> HTTP %d", configResp.code);
    if (configResp.code != 200)
        throw new Exception(text("Failed to fetch API config: HTTP ", configResp.code));

    // Step 2: Login with Basic auth.
    logInfo("Logging in as %s...", username);
    string basicAuth = Base64.encode(
        cast(const(ubyte)[])(encodeComponent(username) ~ ":" ~ encodeComponent(password))
    );
    client.addHeader("Authorization", "Basic " ~ basicAuth);

    HTTPResponse loginResp = client.get("/auth/user");
    client.removeHeader("Authorization"); // Don't send basic auth on subsequent requests.
    logDebugging("login GET /auth/user -> HTTP %d", loginResp.code);

    if (loginResp.code == 401)
        throw new Exception("Login failed: invalid credentials");
    if (loginResp.code != 200)
        throw new Exception(text("Login failed: HTTP ", loginResp.code));

    JSONValue loginJson = parseJSON(loginResp.text);

    // Step 3: Handle 2FA if required.
    if (const(JSONValue) *jrequiresTwoFactorAuth = "requiresTwoFactorAuth" in loginJson)
    {
        handle2FA(config, client, delegator, jrequiresTwoFactorAuth);
        return reAuthUser(client);
    }

    string loginDisplayName;
    if (const(JSONValue)* v = "displayName" in loginJson)
        loginDisplayName = v.str;
    logInfo("Logged in as %s", loginDisplayName);
    return finishAuth(client, loginJson);
}

void handle2FA(ref Config config, HTTPClient client, AuthDelegator delegator, const(JSONValue) *j2fa)
{
    // requiresTwoFactorAuth
    const(JSONValue)[] methods = j2fa.array;
    string method;
    string endpoint;
    foreach (m; methods)
    {
        method = m.str;
        if (method == "totp")
        {
            endpoint = "/auth/twofactorauth/totp/verify";
            break;
        }
        else if (method == "otp")
        {
            endpoint = "/auth/twofactorauth/otp/verify";
            break;
        }
        else if (method == "emailOtp")
        {
            endpoint = "/auth/twofactorauth/emailotp/verify";
            break;
        }
    }

    if (method.length == 0)
        throw new Exception("No supported 2FA method found");

    logInfo("2FA required (method: %s)", method);

    // Allow up to 3 attempts for wrong codes.
    enum MAX_ATTEMPTS = 3;
    bool autoTotpAvailable = method == "totp" && config.totpSecret.length > 0;
    string retryError;
    foreach (attempt; 0 .. MAX_ATTEMPTS)
    {
        string code;
        bool autoAttempt;

        // Try the configured TOTP secret first; on rejection, fall through to
        // the delegator/stdin for the remaining attempts.
        if (autoTotpAvailable)
        {
            try
            {
                code = generateTOTP(config.totpSecret);
                autoAttempt = true;
                logInfo("Generated TOTP code from configured secret (attempt %d/%d)",
                    attempt + 1, MAX_ATTEMPTS);
            }
            catch (Exception e)
            {
                logWarn("TOTP auto-generation failed: %s", e.msg);
                autoTotpAvailable = false;
            }
        }

        if (code.length == 0)
        {
            if (delegator)
            {
                logInfo("Requesting 2FA code from client (attempt %d/%d)...",
                    attempt + 1, MAX_ATTEMPTS);
                AuthResponse dresp = delegator.requestFromClient(
                    AuthRequest(AuthRequestKind.twoFactor, method, retryError));
                if (dresp.cancelled)
                    throw new Exception("Auth delegation timed out or was cancelled");
                code = dresp.code;
            }
            else
            {
                if (attempt > 0)
                    stderr.write("Invalid code, try again. ");
                stderr.write("Enter 2FA code: ");
                code = readln().strip();
            }
        }

        JSONValue payload = JSONValue(["code": JSONValue(code)]);
        HTTPResponse resp = client.postJSON(endpoint, payload.toString());
        logDebugging("POST %s -> HTTP %d", endpoint, resp.code);

        if (resp.code == 200)
        {
            logInfo("2FA verified");
            return;
        }

        if (autoAttempt)
        {
            // Stored secret produced a wrong code (likely stale, wrong, or
            // clock-skewed); stop auto-trying so the delegator/user can step in.
            logWarn("Auto-generated TOTP code rejected; falling back to interactive prompt");
            autoTotpAvailable = false;
            retryError = "Stored TOTP code was rejected, please enter a fresh code";
        }
        else
        {
            retryError = "Invalid 2FA code, please try again";
        }
        logWarn("2FA verification failed (HTTP %d), attempt %d/%d",
            resp.code, attempt + 1, MAX_ATTEMPTS);
    }

    throw new Exception(text("2FA verification failed after ", MAX_ATTEMPTS, " attempts"));
}

AuthState reAuthUser(HTTPClient client)
{
    HTTPResponse userResp = client.get("/auth/user");
    if (userResp.code != 200)
        throw new Exception(text("Failed to get user after 2FA: HTTP ", userResp.code));
    JSONValue userJson = parseJSON(userResp.text);
    string reAuthDisplayName;
    if (const(JSONValue)* v = "displayName" in userJson)
        reAuthDisplayName = v.str;
    logInfo("Logged in as %s", reAuthDisplayName);
    return finishAuth(client, userJson);
}

AuthState finishAuth(HTTPClient client, JSONValue userJson)
{
    // Get WebSocket auth token.
    logInfo("Fetching WebSocket token...");
    HTTPResponse authResp = client.get("/auth");
    logDebugging("GET /auth -> HTTP %d", authResp.code);
    if (authResp.code != 200)
        throw new Exception(text("Failed to get auth token: HTTP ", authResp.code));

    JSONValue authJson = parseJSON(authResp.text);
    string token;
    if (const(JSONValue)* v = "token" in authJson)
        token = v.str;

    if (token.length == 0)
        throw new Exception("Empty auth token received");

    AuthState state;
    state.authToken = token;
    if (const(JSONValue)* v = "id" in userJson)
        state.userId = v.str;
    if (const(JSONValue)* v = "displayName" in userJson)
        state.displayName = v.str;
    if (const(JSONValue)* v = "currentAvatar" in userJson)
        state.currentAvatar = v.str;
    if (const(JSONValue)* v = "status" in userJson)
        state.status = v.str;
    if (const(JSONValue)* v = "statusDescription" in userJson)
        state.statusDescription = v.str;
    if (const(JSONValue)* v = "bio" in userJson)
        if (v.type == JSONType.string)
            state.bio = v.str;
    if (const(JSONValue)* v = "pronouns" in userJson)
        if (v.type == JSONType.string)
            state.pronouns = v.str;
    if (const(JSONValue)* v = "bioLinks" in userJson)
        if (v.type == JSONType.array)
            foreach (ref const(JSONValue) item; v.array)
                if (item.type == JSONType.string)
                    state.bioLinks ~= item.str;
    state.picture = pickUserImage(userJson);
    return state;
}


void saveCredentials(string path, string username, string password)
{
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    string dir = dirName(path);
    if (exists(dir) == false)
        mkdirRecurse(dir);

    JSONValue creds = JSONValue(["username": JSONValue(username), "password": JSONValue(password)]);
    write(path, creds.toPrettyString());
    logInfo("Credentials saved to %s", path);
}
