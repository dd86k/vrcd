/// VRChat authentication
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.vrchat.auth;

import std.json;
import std.base64;
import std.uri : encodeComponent;
import std.string : strip;
import std.stdio : stdin, stderr, write, writeln, readln;
import std.file : exists, readText, mkdirRecurse;
import std.path : dirName;

import ddlogger;
import ddcurl;

import server.authdelegate;
import server.config;
import server.vrchat.vrcconfig : USER_AGENT;

/// Persisted auth state.
struct AuthState
{
    string authToken; /// WebSocket auth token.
    string userId;    /// Current user ID (usr_...).
    string displayName;
    string currentAvatar; /// Self avatar ID at login (avtr_...).
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
    logDebugging("GET /auth/user -> HTTP %d (bodyLen=%d)",
        userResp.code, userResp.text.length);

    if (userResp.code == 200)
    {
        JSONValue userJson = parseJSON(userResp.text);
        if ("requiresTwoFactorAuth" !in userJson)
        {
            string displayName;
            if (const(JSONValue)* v = "displayName" in userJson)
                displayName = v.str;
            logInfo("Session valid, logged in as %s", displayName);
            return finishAuth(client, userJson);
        }
        // 2FA required even with existing cookies.
        handle2FA(client, userJson, delegator);
        return reAuthUser(client);
    }

    // No valid session,  do full login.
    return fullLogin(config, client, delegator);
}

/// Interactive login flow (for `auth` subcommand).
AuthState interactiveLogin(ref Config config, HTTPClient client)
{
    setupClient(client, config);
    return fullLogin(config, client, null);
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
    client.addHeader("Content-Type", "application/json");

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
    else if (delegator !is null)
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
        throw new Exception("Failed to fetch API config: HTTP " ~ intToStr(configResp.code));

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
        throw new Exception("Login failed: HTTP " ~ intToStr(loginResp.code));

    JSONValue loginJson = parseJSON(loginResp.text);

    // Step 3: Handle 2FA if required.
    if ("requiresTwoFactorAuth" in loginJson)
    {
        handle2FA(client, loginJson, delegator);
        return reAuthUser(client);
    }

    string loginDisplayName;
    if (const(JSONValue)* v = "displayName" in loginJson)
        loginDisplayName = v.str;
    logInfo("Logged in as %s", loginDisplayName);
    return finishAuth(client, loginJson);
}

void handle2FA(HTTPClient client, JSONValue loginJson, AuthDelegator delegator)
{
    const(JSONValue)[] methods = loginJson["requiresTwoFactorAuth"].array;
    string method;
    foreach (m; methods)
    {
        string s = m.str;
        if (s == "totp" || s == "otp" || s == "emailOtp")
        {
            method = s;
            break;
        }
    }

    if (method.length == 0)
        throw new Exception("No supported 2FA method found");

    string endpoint;
    if (method == "totp")
        endpoint = "/auth/twofactorauth/totp/verify";
    else if (method == "otp")
        endpoint = "/auth/twofactorauth/otp/verify";
    else
        endpoint = "/auth/twofactorauth/emailotp/verify";

    logInfo("2FA required (method: %s)", method);

    // Allow up to 3 attempts for wrong codes.
    enum MAX_ATTEMPTS = 3;
    string retryError;
    foreach (attempt; 0 .. MAX_ATTEMPTS)
    {
        string code;
        if (delegator !is null)
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

        JSONValue payload = JSONValue(["code": JSONValue(code)]);
        HTTPResponse resp = client.post(endpoint, payload.toString());
        logDebugging("POST %s -> HTTP %d", endpoint, resp.code);

        if (resp.code == 200)
        {
            logInfo("2FA verified");
            return;
        }

        retryError = "Invalid 2FA code, please try again";
        logWarn("2FA verification failed (HTTP %d), attempt %d/%d",
            resp.code, attempt + 1, MAX_ATTEMPTS);
    }

    throw new Exception("2FA verification failed after " ~ intToStr(MAX_ATTEMPTS) ~ " attempts");
}

AuthState reAuthUser(HTTPClient client)
{
    HTTPResponse userResp = client.get("/auth/user");
    if (userResp.code != 200)
        throw new Exception("Failed to get user after 2FA: HTTP " ~ intToStr(userResp.code));
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
        throw new Exception("Failed to get auth token: HTTP " ~ intToStr(authResp.code));

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

string intToStr(int v)
{
    import std.conv : to;
    return to!string(v);
}
