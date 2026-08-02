/// Fake notifications, for working on the inbox without waiting for VRChat.
///
/// The inbox is the hardest part of this front-end to develop against. A
/// friend request arrives when somebody sends one; a group announcement when a
/// group makes one; a queue-ready when a queue clears. None of them can be
/// summoned, several cannot be un-answered, and the ones that draw the most
/// unusual rows are the rarest. So working on that screen means either waiting
/// on other people or editing state into the page by hand.
///
/// This puts a synthetic one in the inbox instead. It travels the same path as
/// a real one -- into the link's inbox, out in the state snapshot, drawn by the
/// same `notifyCard` -- so what appears on screen is what a real one would look
/// like, and answering it exercises the same buttons.
///
/// The catalogue covers every shape `notifyCard` can draw, because the point is
/// to see the unusual ones: a v1 type from the table, a v1 type that answers by
/// joining, a v1 type that cannot be answered at all, a v2 type carrying its own
/// buttons, a v2 type carrying none, one VRChat says it will clear itself (so no
/// buttons at all), and one of a type nobody has written code for.
///
/// Off unless asked for: `--debug`, or `VRCD_WEB_DEBUG` in the environment.
/// With it off none of this is reachable -- the route is not registered, the
/// snapshot carries no `debug` key, and the page draws no chip.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.debugging;

import std.conv : to;
import std.datetime : Clock;
import std.json;
import std.string : startsWith;

import vrcd.notifications;

/// One invented person a fake notification can come from.
///
/// Invented rather than borrowed from the roster, which is what this used to
/// do. Borrowing looked better -- a real face, a profile that really fetches --
/// but it quietly tested the wrong thing: a request from somebody already on
/// the roster opens the *friend* pane, and the whole reason a friend request is
/// worth faking is that its sender is a stranger. A stranger has to be a
/// stranger.
///
/// Nothing is lost by inventing them. A face is initials on a hue picked from
/// the name, which is what the page draws for anyone without a picture anyway
/// -- not a placeholder for one, but what an artless entry looks like.
struct DebugPerson
{
    string userId;
    string displayName;
    string pronouns;
    string bio;
    string trustRank;
    string[] languages;
    string dateJoined;
    string[] badges;
}

/// Three of them, cycled, so a handful of fakes is not one person over and
/// over. They differ in the fields the profile pane draws differently: a
/// Visitor with nothing filled in tests the empty rows, a Trusted User with
/// everything tests the full ones, and the third sits between.
immutable DebugPerson[] DEBUG_PEOPLE = [
    DebugPerson("usr_00000000-0000-4000-8000-00000000d001", "Debug Stranger",
        "they/them", "Invented for testing the profile pane.\n\nSecond line, "
        ~ "so the bio block has a paragraph break to render.",
        "Known User", [ "eng", "jpn" ], "2019-04-01",
        [ "Supporter", "Early Adopter" ]),
    DebugPerson("usr_00000000-0000-4000-8000-00000000d002", "Debug Visitor",
        null, null, "Visitor", null, "2026-07-30", null),
    DebugPerson("usr_00000000-0000-4000-8000-00000000d003", "Debug Veteran",
        "she/her", "Ten years in, still no idea what is going on.",
        "Trusted User", [ "eng" ], "2016-02-14",
        [ "Veteran", "Supporter", "Content Creator" ]),
];

/// Whether this user ID is one of the invented people.
bool isDebugUser(string userId)
{
    foreach (ref const DebugPerson person; DEBUG_PEOPLE)
    {
        if (person.userId == userId)
            return true;
    }
    return false;
}

/// Build the `user` payload for one invented person, in the shape vrcd-server
/// would have sent for a real one.
///
/// Badges carry no `imageUrl`: their art lives on VRChat's CDN and cannot be
/// invented, and a made-up URL would only be a fetch that fails. The grid draws
/// the names, which is what it falls back to for a badge whose art does not
/// arrive anyway.
JSONValue buildFakeProfile(string userId)
{
    foreach (ref const DebugPerson person; DEBUG_PEOPLE)
    {
        if (person.userId != userId)
            continue;

        JSONValue[] badges;
        foreach (string name; person.badges)
        {
            badges ~= JSONValue([
                "id":          JSONValue("bdg_debug_" ~ name),
                "name":        JSONValue(name),
                "description": JSONValue("An invented badge."),
                "imageUrl":    JSONValue(""),
                "showcased":   JSONValue(badges.length == 0),
            ]);
        }

        JSONValue profile = JSONValue.emptyObject;
        profile["id"]                  = JSONValue(person.userId);
        profile["displayName"]         = JSONValue(person.displayName);
        profile["status"]              = JSONValue("active");
        profile["statusDescription"]   = JSONValue("");
        profile["bio"]                 = JSONValue(person.bio);
        profile["bioLinks"]            = JSONValue([ "https://example.invalid" ]);
        profile["pronouns"]            = JSONValue(person.pronouns);
        profile["note"]                = JSONValue("");
        profile["state"]               = JSONValue("offline");
        profile["location"]            = JSONValue("");
        profile["platform"]            = JSONValue("standalonewindows");
        profile["dateJoined"]          = JSONValue(person.dateJoined);
        profile["lastActivity"]        = JSONValue("");
        profile["lastLogin"]           = JSONValue("");
        profile["friendRequestStatus"] = JSONValue("incoming");
        profile["isFriend"]            = JSONValue(false);
        profile["ageVerified"]         = JSONValue(person.trustRank == "Trusted User");
        profile["trustRank"]           = JSONValue(person.trustRank);
        profile["languages"]           = JSONValue(person.languages);
        profile["moderator"]           = JSONValue(false);
        profile["troll"]               = JSONValue(false);
        profile["badges"]              = JSONValue(badges);
        // No picture: the initials disc underneath is the face, the same as for
        // any real user who has not set one.
        profile["imageFileId"]         = JSONValue("");
        profile["imageVersion"]        = JSONValue(1);
        return profile;
    }
    return JSONValue.init;
}

/// Prefix on every fake notification's ID.
///
/// It is what tells one apart from a real notification later, when an answer
/// comes back for it: a real one has to go down the link to VRChat, and a fake
/// one has nowhere to go and is answered here. VRChat's own IDs are
/// `not_<uuid>`, so this cannot collide with one.
enum string DEBUG_ID_PREFIX = "not_debug_";

/// Whether this ID belongs to a fake notification.
bool isDebugNotification(string id)
{
    return startsWith(id, DEBUG_ID_PREFIX);
}

/// One entry in the catalogue: what the page draws a button for, and what
/// pressing it makes.
struct DebugFake
{
    /// Sent back as the action on `POST /api/debug`.
    string action;
    /// Button label on the page.
    string label;
    /// One line under it, saying what the row it makes is for.
    string hint;
}

/// Every fake on offer, in the order the page shows them.
///
/// The friend request is first because it is the one worth having: it is the
/// row with two buttons where the wrong one is an accept, and the only row
/// whose sender is somebody you are not friends with -- which is the whole
/// reason the profile pane fetches strangers.
immutable DebugFake[] DEBUG_FAKES = [
    DebugFake("friend_request", "FRIEND REQUEST",
        "A v1 friend request: ACCEPT and DECLINE, and a sender you can open."),
    DebugFake("invite", "INVITE",
        "A v1 invite carrying a location, so the row offers JOIN WORLD."),
    DebugFake("request_invite", "INVITE REQUEST",
        "A v1 type that cannot be answered from here: dismiss and a note."),
    DebugFake("group_invite", "GROUP INVITE",
        "A v2 notification drawing its buttons from its own responses."),
    DebugFake("group_announcement", "ANNOUNCEMENT",
        "A v2 notification with no responses: a title, a body, a dismiss."),
    DebugFake("queue_ready", "QUEUE READY",
        "One VRChat clears itself, so the row gets no buttons at all."),
    DebugFake("unknown", "UNKNOWN TYPE",
        "A type this build has never heard of, to check it still draws."),
];

/// Whether this is one of the catalogue's actions.
bool isDebugFake(string action)
{
    foreach (ref const DebugFake fake; DEBUG_FAKES)
    {
        if (fake.action == action)
            return true;
    }
    return false;
}

/// Build one fake notification.
///
/// Params:
///   action = One of `DEBUG_FAKES`.
///   seq = Counter making the ID unique, so pressing a button twice makes two
///         rows rather than one that is silently dropped as a repeat. Also
///         picks which of `DEBUG_PEOPLE` it comes from, so a handful of fakes
///         is not one person over and over.
NotificationInfo buildFakeNotification(string action, long seq)
{
    const DebugPerson sender = DEBUG_PEOPLE[
        cast(size_t)(seq % DEBUG_PEOPLE.length)];

    NotificationInfo info;
    info.id = DEBUG_ID_PREFIX ~ action ~ "_" ~ seq.to!string();
    info.receivedAtUnix = Clock.currTime.toUnixTime!long();
    info.senderUserId = sender.userId;
    info.senderName = sender.displayName;

    switch (action)
    {
    case "friend_request":
        info.notificationType = "friendRequest";
        info.message = "wants to be your friend";
        break;

    case "invite":
        info.notificationType = "invite";
        info.message = "The Great Pug";
        // A real location, in the shape the join button parses: the row has to
        // be able to offer a join, and the pane a self-invite.
        info.location = "wrld_4432ea9b-729c-46e3-8eaf-846aa0a37fdd:12345~region(us)";
        break;

    case "request_invite":
        info.notificationType = "requestInvite";
        info.message = "would like an invite";
        break;

    case "group_invite":
        info.apiVersion = 2;
        info.notificationType = "group.invite";
        // As VRChat does it: a group notification puts the group's own ID
        // where a user ID goes, which is what the page has to notice to keep
        // from trying to open a person who is not one.
        info.senderUserId = "grp_00000000-0000-4000-8000-000000000001";
        info.senderName = null;
        info.title = "Debug Group";
        info.message = "You have been invited to join Debug Group";
        info.responses = [
            NotificationResponse("accept", "Accept", "check", ""),
            NotificationResponse("decline", "Decline", "cancel", ""),
        ];
        break;

    case "group_announcement":
        info.apiVersion = 2;
        info.notificationType = "group.announcement";
        info.senderUserId = "grp_00000000-0000-4000-8000-000000000001";
        info.senderName = null;
        info.title = "Debug Group";
        info.message = "Movie night at 8, bring your own avatar.";
        break;

    case "queue_ready":
        info.apiVersion = 2;
        info.notificationType = "group.queueReady";
        info.senderUserId = "grp_00000000-0000-4000-8000-000000000001";
        info.senderName = null;
        info.title = "Your queue is ready";
        info.message = "You can join the instance now.";
        // VRChat expires this one on its own and refuses to be told to, so the
        // row is read-only. A dismiss button on it would only fail.
        info.canDelete = false;
        break;

    case "unknown":
        info.notificationType = "debug.somethingNew";
        info.message = "A type this build has never heard of.";
        break;

    default:
        return NotificationInfo.init;
    }

    return info;
}

unittest
{
    assert(isDebugNotification("not_debug_friend_request_1"));
    assert(isDebugNotification("not_8b5e4d3c-0000-4000-8000-1a2b3c4d5e6f") == false);
    assert(isDebugNotification("") == false);

    assert(isDebugFake("friend_request"));
    assert(isDebugFake("clear") == false);
    assert(isDebugFake("") == false);

    // The one worth having comes first.
    assert(DEBUG_FAKES[0].action == "friend_request");
}

unittest
{
    NotificationInfo request = buildFakeNotification("friend_request", 1);
    assert(request.id == "not_debug_friend_request_1");
    assert(isDebugNotification(request.id));
    assert(request.notificationType == "friendRequest");
    assert(request.apiVersion == 1);
    assert(request.canDelete);

    // The sender is invented, never borrowed: a request from somebody already
    // on the roster would open the friend pane, and the point of faking one is
    // that its sender is a stranger.
    assert(isDebugUser(request.senderUserId));
    assert(request.senderName.length > 0);
    // And it looks like a user ID, or the row would not offer to open it.
    assert(startsWith(request.senderUserId, "usr_"));

    // The counter is what keeps two presses from collapsing into one row: the
    // inbox drops a notification whose ID it already holds.
    assert(buildFakeNotification("friend_request", 2).id != request.id);
    // It also moves the sender on, so a handful is not one person repeated.
    assert(buildFakeNotification("friend_request", 2).senderUserId
        != request.senderUserId);

    // An invite has somewhere to go, which is how its row offers a join.
    assert(buildFakeNotification("invite", 1).location.length > 0);

    // A group notification carries a group ID where a user ID goes, which is
    // what the page has to notice to keep from opening a person who is not one.
    NotificationInfo invite = buildFakeNotification("group_invite", 1);
    assert(invite.apiVersion == 2);
    assert(startsWith(invite.senderUserId, "grp_"));
    assert(invite.responses.length == 2);

    // The one VRChat clears itself gets no buttons.
    assert(buildFakeNotification("queue_ready", 1).canDelete == false);

    // An action outside the catalogue makes nothing, which callers test for
    // the same way they test a failed parse.
    assert(buildFakeNotification("nope", 1).id.length == 0);
}

unittest
{
    // Every invented person has a profile, and it is the shape the profile
    // pane reads: the same keys vrcd-server sends for a real one.
    foreach (ref const DebugPerson person; DEBUG_PEOPLE)
    {
        assert(isDebugUser(person.userId));

        JSONValue profile = buildFakeProfile(person.userId);
        assert(profile.type == JSONType.object);
        assert(profile["id"].str == person.userId);
        assert(profile["displayName"].str == person.displayName);
        assert(profile["trustRank"].str == person.trustRank);
        assert(profile["badges"].array.length == person.badges.length);
        // Never a friend: that is the state the pane exists to draw.
        assert(profile["isFriend"].type == JSONType.false_);
        // No picture, so the initials disc is the face, as for any real user
        // who has not set one.
        assert(profile["imageFileId"].str.length == 0);
    }

    // Badge art cannot be invented, so there is none to fetch.
    JSONValue withBadges = buildFakeProfile(DEBUG_PEOPLE[0].userId);
    assert(withBadges["badges"].array[0]["imageUrl"].str.length == 0);
    assert(withBadges["badges"].array[0]["showcased"].type == JSONType.true_);

    // Anybody else is not ours to answer for.
    assert(isDebugUser("usr_8b5e4d3c-0000-4000-8000-1a2b3c4d5e6f") == false);
    assert(buildFakeProfile("usr_8b5e4d3c").type != JSONType.object);
}
