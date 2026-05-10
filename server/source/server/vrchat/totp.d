/// RFC 6238 TOTP code generation
///
/// Used to auto-answer VRChat's "totp" 2FA challenge from a stored secret
/// so the server can reconnect unattended.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.vrchat.totp;

import std.datetime.systime : Clock;
import std.digest.hmac : hmac;
import std.digest.sha : SHA1;
import std.format : format;
import std.string : strip;

/// Generate a TOTP code (RFC 6238) for the given base32 secret.
///
/// Default parameters (30-second step, 6 digits, SHA-1) match what
/// VRChat's authenticator enrollment hands out.
///
/// `unixTime` < 0 means "use the current wall-clock time".
string generateTOTP(string base32Secret, long unixTime = -1, int digits = 6, int step = 30)
{
    if (unixTime < 0)
        unixTime = Clock.currTime.toUnixTime!long();

    ubyte[] key = base32Decode(base32Secret.strip());
    if (key.length == 0)
        throw new Exception("TOTP secret decoded to empty key");

    long counter = unixTime / step;
    ubyte[8] counterBytes = void;
    for (int i = 7; i >= 0; --i)
    {
        counterBytes[i] = cast(ubyte)counter;
        counter >>= 8;
    }

    ubyte[20] digest = hmac!SHA1(counterBytes[], key);
    int offset = digest[19] & 0x0f;
    uint binary =
        ((digest[offset]     & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) <<  8) |
         (digest[offset + 3] & 0xff);

    uint mod = 1;
    foreach (i; 0 .. digits)
        mod *= 10;
    return format!"%0*d"(digits, binary % mod);
}

/// Decode an RFC 4648 base32 string. Tolerates whitespace, dashes,
/// padding, and lowercase letters (commonly seen in QR-code secrets).
private ubyte[] base32Decode(string input)
{
    ubyte[] result;
    result.reserve(input.length * 5 / 8);

    uint buffer;
    int bits;
    foreach (char c; input)
    {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '-' || c == '=')
            continue;

        char u = c;
        if (u >= 'a' && u <= 'z')
            u = cast(char)(u - 32);

        int v;
        if (u >= 'A' && u <= 'Z')
            v = u - 'A';
        else if (u >= '2' && u <= '7')
            v = 26 + (u - '2');
        else
            throw new Exception("Invalid base32 character in TOTP secret");

        buffer = (buffer << 5) | v;
        bits += 5;
        if (bits >= 8)
        {
            bits -= 8;
            result ~= cast(ubyte)((buffer >> bits) & 0xff);
        }
    }
    return result;
}

unittest
{
    // RFC 6238 Appendix B test vectors (SHA-1, secret = "12345678901234567890").
    // Base32 of that ASCII string:
    enum string secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

    // T=59 -> 94287082 -> last 6 digits = 287082
    assert(generateTOTP(secret, 59) == "287082");
    // T=1111111109 -> 07081804 -> 081804
    assert(generateTOTP(secret, 1111111109) == "081804");
    // T=1111111111 -> 14050471 -> 050471
    assert(generateTOTP(secret, 1111111111) == "050471");
    // T=1234567890 -> 89005924 -> 005924
    assert(generateTOTP(secret, 1234567890) == "005924");
    // T=2000000000 -> 69279037 -> 279037
    assert(generateTOTP(secret, 2000000000) == "279037");
}

unittest
{
    // Whitespace, dashes and lowercase are accepted (matches how
    // authenticator apps commonly format the secret).
    enum string secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
    assert(generateTOTP("gezd-gnbv-gy3t-qojq-gezd-gnbv-gy3t-qojq", 59) == "287082");
    assert(generateTOTP("GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ", 59) == "287082");
    assert(generateTOTP(secret ~ "====", 59) == "287082");
}

unittest
{
    import std.exception : assertThrown;
    assertThrown(generateTOTP("not!base32", 0));
    assertThrown(generateTOTP("", 0));
}
