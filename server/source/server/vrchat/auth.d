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

import server.config;
import server.vrchat.vrcconfig : USER_AGENT;

/// Persisted auth state.
struct AuthState
{
    string authToken; /// WebSocket auth token.
    string userId;    /// Current user ID (usr_...).
    string displayName;
}

/// Authenticate with VRChat and obtain a WebSocket token.
///
/// Uses cookie jar for session persistence. If cookies are still valid,
/// skips login. Otherwise performs full login + optional 2FA.
AuthState authenticate(ref Config config, HTTPClient client)
{
    setupClient(client, config);

    // Try existing session first.
    logInfo("Checking existing session...");
    HTTPResponse userResp = client.get("/auth/user");

    if (userResp.code == 200)
    {
        JSONValue userJson = parseJSON(userResp.text);
        if ("requiresTwoFactorAuth" !in userJson)
        {
            logInfo("Session valid, logged in as %s", jsonStr(userJson, "displayName"));
            return finishAuth(client, userJson);
        }
        // 2FA required even with existing cookies.
        handle2FA(client, userJson);
        return reAuthUser(client);
    }

    // No valid session — do full login.
    return fullLogin(config, client);
}

/// Interactive login flow (for `auth` subcommand).
AuthState interactiveLogin(ref Config config, HTTPClient client)
{
    setupClient(client, config);
    return fullLogin(config, client);
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
    if (!exists(dir))
        mkdirRecurse(dir);
    client.setCookieJar(cookiePath);
}

AuthState fullLogin(ref Config config, HTTPClient client)
{
    // Read credentials.
    string username, password;
    if (exists(config.credentialsPath))
    {
        logInfo("Reading credentials from %s", config.credentialsPath);
        JSONValue creds = parseJSON(readText(config.credentialsPath));
        username = jsonStr(creds, "username");
        password = jsonStr(creds, "password");
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

    if (loginResp.code == 401)
        throw new Exception("Login failed: invalid credentials");
    if (loginResp.code != 200)
        throw new Exception("Login failed: HTTP " ~ intToStr(loginResp.code));

    JSONValue loginJson = parseJSON(loginResp.text);

    // Step 3: Handle 2FA if required.
    if ("requiresTwoFactorAuth" in loginJson)
    {
        handle2FA(client, loginJson);
        return reAuthUser(client);
    }

    logInfo("Logged in as %s", jsonStr(loginJson, "displayName"));
    return finishAuth(client, loginJson);
}

void handle2FA(HTTPClient client, JSONValue loginJson)
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

    logInfo("2FA required (method: %s)", method);
    stderr.write("Enter 2FA code: ");
    string code = readln().strip();

    // NOTE: Move this earlier in function and assert pre-emptively if method not supported
    string endpoint;
    if (method == "totp")
        endpoint = "/auth/twofactorauth/totp/verify";
    else if (method == "otp")
        endpoint = "/auth/twofactorauth/otp/verify";
    else
        endpoint = "/auth/twofactorauth/emailotp/verify";

    JSONValue payload = JSONValue(["code": JSONValue(code)]);
    HTTPResponse resp = client.post(endpoint, payload.toString());

    if (resp.code != 200)
        throw new Exception("2FA verification failed: HTTP " ~ intToStr(resp.code));

    logInfo("2FA verified");
}

AuthState reAuthUser(HTTPClient client)
{
    HTTPResponse userResp = client.get("/auth/user");
    if (userResp.code != 200)
        throw new Exception("Failed to get user after 2FA: HTTP " ~ intToStr(userResp.code));
    JSONValue userJson = parseJSON(userResp.text);
    logInfo("Logged in as %s", jsonStr(userJson, "displayName"));
    return finishAuth(client, userJson);
}

AuthState finishAuth(HTTPClient client, JSONValue userJson)
{
    // Get WebSocket auth token.
    logInfo("Fetching WebSocket token...");
    HTTPResponse authResp = client.get("/auth");
    if (authResp.code != 200)
        throw new Exception("Failed to get auth token: HTTP " ~ intToStr(authResp.code));

    JSONValue authJson = parseJSON(authResp.text);
    string token = jsonStr(authJson, "token");

    if (token.length == 0)
        throw new Exception("Empty auth token received");

    AuthState state;
    state.authToken = token;
    state.userId = jsonStr(userJson, "id");
    state.displayName = jsonStr(userJson, "displayName");
    return state;
}

/// Helper to safely extract a string from JSON.
string jsonStr(JSONValue json, string key)
{
    if (key in json && json[key].type == JSONType.string)
        return json[key].str;
    return "";
}

void saveCredentials(string path, string username, string password)
{
    import std.file : write, mkdirRecurse;
    import std.path : dirName;

    string dir = dirName(path);
    if (!exists(dir))
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
