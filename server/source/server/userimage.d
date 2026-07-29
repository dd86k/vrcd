/// VRChat user pictures, reduced to the file an image request can ask for.
///
/// VRChat describes the same thing -- "what this user looks like in a list" --
/// with up to five fields, and hands them out as absolute URLs. Front-ends
/// cannot fetch those URLs (only the server holds the VRChat session), so what
/// travels to a client is the file behind one of them: an ID and a version,
/// which is exactly what the image endpoints take.
///
/// Picking which of the five is a decision, and it is made here so the server,
/// the SDL client and the web front-end cannot disagree about whose face a
/// friend has. The order follows VRCX's defaults: an explicit profile picture
/// wins over the VRC+ icon, which wins over whatever avatar they happen to be
/// wearing.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.userimage;

import std.ascii : isAlphaNum;
import std.conv : ConvException, to;
import std.json;
import std.string : indexOf;

/// One user picture, as something the image endpoints can serve.
struct UserImage
{
    /// "file_..." of the picture, or empty when the user has none we can ask
    /// for.
    string fileId;
    /// File version, 1 or higher whenever `fileId` is set.
    long fileVersion;
}

/// VRChat's "robot" placeholder, served while a real avatar image is still
/// being generated. It says nothing about the user, so it counts as no picture
/// at all (cf. VRCX src/stores/user.js).
enum string robotAvatarFileId = "file_0e8c4e32-7444-44ea-ade4-313c010d4bae";

/// The user fields that hold a picture, best first.
///
/// The thumbnail variants come before their full-size counterparts only
/// because VRChat fills them in for anything it has resized already; both
/// point at the same file, so the pick is the same either way.
immutable string[] userImageFields = [
    "profilePicOverrideThumbnail",
    "profilePicOverride",
    "userIcon",
    "currentAvatarThumbnailImageUrl",
    "currentAvatarImageUrl",
];

/// Pick the picture to show for a user object (a REST friend entry, the
/// logged-in user, or the "user" sub-object of a WebSocket frame).
UserImage pickUserImage(JSONValue user)
{
    if (user.type != JSONType.object)
        return UserImage.init;

    foreach (string field; userImageFields)
    {
        const(JSONValue)* v = field in user;
        if (v is null || v.type != JSONType.string)
            continue;

        UserImage picture = parseImageURL(v.str);
        if (picture.fileId.length > 0)
            return picture;
    }
    return UserImage.init;
}

/// Pull the file out of a VRChat image URL.
///
/// Both shapes VRChat serves carry the file and its version in the path:
/// `/api/1/file/<file id>/<version>/file` for an original and
/// `/api/1/image/<file id>/<version>/<size>` for a resize. Anything else --
/// most notably the old CloudFront thumbnails, which are not files at all --
/// comes back empty, which reads as "no picture" rather than an error: a
/// friend with a legacy avatar image simply has nothing to fetch.
UserImage parseImageURL(string url)
{
    UserImage result;

    // The path is all that matters; a query string only gets in the way.
    ptrdiff_t cut = url.indexOf('?');
    if (cut >= 0)
        url = url[0 .. cut];

    ptrdiff_t at = url.indexOf("file_");
    if (at < 0)
        return result;
    // Has to be a whole path segment, not a substring of a longer name.
    if (at > 0 && url[at - 1] != '/')
        return result;

    string rest = url[at .. $];
    ptrdiff_t slash = rest.indexOf('/');
    string fileId = slash < 0 ? rest : rest[0 .. slash];
    if (isFileId(fileId) == false || fileId == robotAvatarFileId)
        return result;

    // Missing or unreadable version: version 1 is the only one every file has.
    long fileVersion = 1;
    if (slash >= 0)
    {
        string tail = rest[slash + 1 .. $];
        ptrdiff_t next = tail.indexOf('/');
        string text = next < 0 ? tail : tail[0 .. next];
        try fileVersion = text.to!long();
        catch (ConvException) fileVersion = 1;
    }
    if (fileVersion < 1)
        fileVersion = 1;

    result.fileId = fileId;
    result.fileVersion = fileVersion;
    return result;
}

/// Whether this is a VRChat file ID. The ID ends up in a path on both the
/// server and the front-ends, so nothing but the documented shape passes.
private bool isFileId(string value)
{
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

unittest
{
    // A resize: file and version come straight out of the path.
    UserImage thumb = parseImageURL(
        "https://api.vrchat.cloud/api/1/image/file_abc-123/3/256");
    assert(thumb.fileId == "file_abc-123");
    assert(thumb.fileVersion == 3);

    // An original, where the last segment is "file" rather than a size.
    UserImage full = parseImageURL(
        "https://api.vrchat.cloud/api/1/file/file_abc-123/2/file");
    assert(full.fileId == "file_abc-123");
    assert(full.fileVersion == 2);

    // Nothing to fetch: legacy CloudFront thumbnails, the robot placeholder,
    // and an empty field all mean "no picture".
    assert(parseImageURL(
        "https://d348imysud55la.cloudfront.net/thumbnails/x.thumbnail-500.png")
        .fileId.length == 0);
    assert(parseImageURL("https://api.vrchat.cloud/api/1/image/"
        ~ robotAvatarFileId ~ "/1/256").fileId.length == 0);
    assert(parseImageURL("").fileId.length == 0);

    // A version that is not a number leaves version 1, which every file has.
    assert(parseImageURL("https://api.vrchat.cloud/api/1/file/file_abc/x/file")
        .fileVersion == 1);
}

unittest
{
    // An explicit profile picture beats the icon, which beats the avatar.
    JSONValue user = parseJSON(`{
        "profilePicOverride": "https://api.vrchat.cloud/api/1/file/file_pic/1/file",
        "userIcon": "https://api.vrchat.cloud/api/1/file/file_icon/1/file",
        "currentAvatarThumbnailImageUrl": "https://api.vrchat.cloud/api/1/image/file_av/1/256"
    }`);
    assert(pickUserImage(user).fileId == "file_pic");

    // Empty fields are skipped rather than taken as an answer.
    JSONValue iconOnly = parseJSON(`{
        "profilePicOverride": "",
        "userIcon": "https://api.vrchat.cloud/api/1/file/file_icon/1/file",
        "currentAvatarThumbnailImageUrl": "https://api.vrchat.cloud/api/1/image/file_av/1/256"
    }`);
    assert(pickUserImage(iconOnly).fileId == "file_icon");

    // A friend wearing an avatar VRChat has not resized yet still has a face:
    // the full-size URL points at the same file.
    JSONValue avatarOnly = parseJSON(`{
        "currentAvatarImageUrl": "https://api.vrchat.cloud/api/1/file/file_av/4/file"
    }`);
    UserImage picture = pickUserImage(avatarOnly);
    assert(picture.fileId == "file_av");
    assert(picture.fileVersion == 4);

    assert(pickUserImage(parseJSON(`{"displayName":"nobody"}`)).fileId.length == 0);
}
