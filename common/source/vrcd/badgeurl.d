/// What may be fetched as badge art.
///
/// Badges are the one picture in a VRChat profile that is not a VRChat file:
/// they sit on a public asset CDN, so there is no file ID for the image
/// endpoints to be handed, only an absolute URL VRChat put in the user object.
///
/// A front-end could load that URL itself, and it would be six lines. None of
/// them do, because they make no external requests on purpose: one that phoned
/// out would break behind a tunnel, and would tell VRChat's CDN who is looking
/// at whom. So badge art travels the same path as every other picture, which
/// makes it the one request where a client names a *URL* rather than an object.
///
/// That is the reason this rule lives in `common` rather than on either side
/// of the link. vrcd-server checks it before fetching anything, and the web
/// front-end checks it before putting a request on the link at all; if the two
/// ever disagreed, the looser one would be the real rule.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.badgeurl;

import std.ascii : isAlphaNum;
import std.string : startsWith;

/// The only host badge art is fetched from. An allowlist rather than a
/// pattern: "somewhere under vrchat.com" is a larger promise than anything
/// here needs, and this is a fetch-by-URL.
enum string BADGE_HOST = "https://assets.vrchat.com";

/// The only path under it. VRChat's badge art has lived here since badges
/// existed; one served from anywhere else simply does not load, and a
/// front-end falls back to the badge's name, which is the part that means
/// something.
enum string BADGE_PATH = "/badges/";

/// Longest URL entertained. A badge URL is a host, a directory and a UUID.
private enum size_t URL_MAX = 512;

/// Whether this URL may be fetched as badge art.
///
/// Everything about it is pinned: the scheme, the host, and the directory
/// under it. What is left is a file name, checked character by character, so
/// there is no `..`, no second host smuggled in as userinfo, no query string,
/// no fragment, and nothing that is not a printable path character.
bool isBadgeImageURL(string url)
{
    if (url.length == 0 || url.length > URL_MAX)
        return false;
    if (startsWith(url, BADGE_HOST ~ BADGE_PATH) == false)
        return false;

    string rest = url[BADGE_HOST.length + BADGE_PATH.length .. $];
    if (rest.length == 0)
        return false;

    foreach (char c; rest)
    {
        // Percent escapes are not decoded anywhere on the way to cURL, so
        // allowing them would only be a second spelling for the characters
        // below -- and a way to spell the ones refused.
        if (isAlphaNum(c) == false && c != '-' && c != '_' && c != '.' && c != '/')
            return false;
    }

    // Checked per segment, not over the whole tail: "." and ".." are what
    // climbing out of the directory looks like, and every character in them is
    // one the loop above allows.
    size_t start;
    foreach (size_t i; 0 .. rest.length + 1)
    {
        if (i < rest.length && rest[i] != '/')
            continue;

        string segment = rest[start .. i];
        if (segment.length == 0 || segment == "." || segment == "..")
            return false;
        start = i + 1;
    }
    return true;
}

unittest
{
    // What VRChat actually serves.
    assert(isBadgeImageURL(
        "https://assets.vrchat.com/badges/fa/bdgai_583f6b13-91ab-4e1b-974e-ab91600b06cb.png"));
    // A dot in a file name is not a dot segment.
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/fa/x.y.png"));

    // Wrong scheme, wrong host, wrong directory.
    assert(isBadgeImageURL("http://assets.vrchat.com/badges/fa/x.png") == false);
    assert(isBadgeImageURL(
        "https://assets.vrchat.com.evil.invalid/badges/fa/x.png") == false);
    assert(isBadgeImageURL(
        "https://api.vrchat.cloud/api/1/file/file_x/1/file") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/avatars/x.png") == false);

    // A second host smuggled in, a query, a fragment, a header injection:
    // none of these are path characters, so none of them survive.
    assert(isBadgeImageURL(
        "https://assets.vrchat.com/badges/@evil.invalid/x.png") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/x.png?a=b") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/x.png#f") == false);
    assert(isBadgeImageURL(
        "https://assets.vrchat.com/badges/x.png\r\nHost: evil") == false);

    // Climbing out of the directory, spelled plainly and spelled in escapes.
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/../secret") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/fa/../../secret") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/%2e%2e/secret") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/./x.png") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/fa//x.png") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/x.png/") == false);
    assert(isBadgeImageURL("https://assets.vrchat.com/badges/") == false);
    assert(isBadgeImageURL("") == false);
}
