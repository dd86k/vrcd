/// Promotion rules as they travel between vrcd-server and the front-ends.
///
/// The server is what runs them; this is the shape and the per-rule checks,
/// shared so a front-end can refuse an edit the server would refuse anyway
/// instead of finding out a round trip later.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.promotions;

import std.algorithm.searching : startsWith;
import std.json;

/// Bounds on what a front-end may store, since the whole set is re-broadcast
/// to every front-end and walked on every event.
enum size_t RULES_MAX = 100;
enum size_t RULE_USERS_MAX = 200;
enum size_t RULE_NAME_MAX = 64;

/// The rule the profile pages' "Notify When Online" toggles add people to.
/// One shared rule rather than one per person, so watching twenty friends is
/// one row in the editor, and a fixed ID so every front-end finds the same one.
enum string WATCH_RULE_ID = "watch-online";
enum string WATCH_RULE_NAME = "Watched friends";
enum string WATCH_RULE_EVENT = "friend-online";
enum long WATCH_RULE_COOLDOWN = 300;

struct PromotionRule
{
    string id;
    string name;
    bool enabled = true;
    /// Raw or synthetic event types, e.g. "friend-delete".
    string[] events;
    /// User IDs the event must be about; empty matches anyone.
    string[] users;
    /// Seconds a rule stays quiet for the same user after firing, so a friend
    /// whose connection flaps does not fill the inbox.
    long cooldown;
}

/// A heading in a rule editor and the event types listed under it.
struct PromotableGroup
{
    string title;
    immutable(string)[] rawTypes;
}

/// What an editor offers. Only events vrcd-server sees and that are about
/// somebody: local log events never reach it, notifications are already
/// notifications, and `friend-traveling` is never broadcast as an event the
/// rules are run on.
immutable PromotableGroup[] promotableEvents = [
    PromotableGroup("Friends", [
        "friend-online", "friend-offline", "friend-active",
        "friend-location", "friend-add", "friend-delete",
    ]),
    PromotableGroup("Changes", [
        "avatar-change", "profile-change",
    ]),
    PromotableGroup("Account", [
        "user-badge-assigned", "group-joined", "group-left",
    ]),
];

/// Quiet periods an editor offers, in seconds. Presets rather than a number
/// box, since typing in a headset is the expensive part of an editor.
immutable long[] cooldownPresets = [ 0, 60, 300, 900, 3600 ];

JSONValue buildRuleJSON(ref const(PromotionRule) rule)
{
    JSONValue[] events, users;
    foreach (string e; rule.events)
        events ~= JSONValue(e);
    foreach (string u; rule.users)
        users ~= JSONValue(u);
    return JSONValue([
        "id":       JSONValue(rule.id),
        "name":     JSONValue(rule.name),
        "enabled":  JSONValue(rule.enabled),
        "events":   JSONValue(events),
        "users":    JSONValue(users),
        "cooldown": JSONValue(rule.cooldown),
    ]);
}

JSONValue buildRulesJSON(const(PromotionRule)[] rules)
{
    JSONValue[] items;
    items.reserve(rules.length);
    foreach (ref const(PromotionRule) rule; rules)
        items ~= buildRuleJSON(rule);
    return JSONValue(items);
}

/// Parse and check one rule. Returns an error message, or null. What it
/// cannot check is left to the caller: IDs unique across the set, and event
/// types the server knows to be notifications.
string parseRule(const(JSONValue) jrule, out PromotionRule rule)
{
    if (jrule.type != JSONType.object)
        return "A rule must be an object";

    rule.id = stringField(jrule, "id");
    if (rule.id.length == 0 || rule.id.length > RULE_NAME_MAX)
        return "A rule needs an id";

    rule.name = stringField(jrule, "name");
    if (rule.name.length > RULE_NAME_MAX)
        return "Rule name too long";

    if (const(JSONValue)* v = "enabled" in jrule)
        rule.enabled = v.type != JSONType.false_;

    if (const(JSONValue)* v = "cooldown" in jrule)
    {
        if (v.type != JSONType.integer || v.integer < 0)
            return "cooldown must be a non-negative integer";
        rule.cooldown = v.integer;
    }

    if (string error = stringList(jrule, "events", rule.events))
        return error;
    if (rule.events.length == 0)
        return "A rule needs at least one event";

    if (string error = stringList(jrule, "users", rule.users))
        return error;
    if (rule.users.length > RULE_USERS_MAX)
        return "Too many users in one rule";
    foreach (string u; rule.users)
        if (u.startsWith("usr_") == false)
            return "Not a user ID: " ~ u;

    return null;
}

/// Decode a `promotions` message. A rule that does not parse is skipped:
/// the server only stores sets that do, so one here is from a newer server.
PromotionRule[] parsePromotionsMessage(ref const(JSONValue) msg)
{
    PromotionRule[] rules;
    if (const(JSONValue)* items = "rules" in msg)
    {
        if (items.type != JSONType.array)
            return rules;
        foreach (const(JSONValue) item; items.array)
        {
            PromotionRule rule;
            if (parseRule(item, rule) is null)
                rules ~= rule;
        }
    }
    return rules;
}

private:

string stringList(const(JSONValue) obj, string key, out string[] list)
{
    const(JSONValue)* v = key in obj;
    if (v is null)
        return null;
    if (v.type != JSONType.array)
        return key ~ " must be an array";
    foreach (const(JSONValue) item; v.array)
    {
        if (item.type != JSONType.string || item.str.length == 0)
            return key ~ " must hold strings";
        list ~= item.str;
    }
    return null;
}

string stringField(const(JSONValue) obj, string key)
{
    if (obj.type != JSONType.object)
        return null;
    if (const(JSONValue)* v = key in obj)
        if (v.type == JSONType.string)
            return v.str;
    return null;
}

unittest
{
    PromotionRule rule;
    rule.id = "a";
    rule.events = [ "friend-online" ];
    rule.users = [ "usr_alice" ];
    rule.cooldown = 60;

    JSONValue msg = JSONValue([
        "type":  JSONValue("promotions"),
        "rules": buildRulesJSON([ rule ]),
    ]);
    PromotionRule[] back = parsePromotionsMessage(msg);
    assert(back.length == 1 && back[0] == rule);

    PromotionRule bad;
    assert(parseRule(parseJSON(`{"id":"b","events":["x"],"users":["bob"]}`), bad));
    assert(parseRule(parseJSON(`{"id":"b","events":[]}`), bad));
    assert(parseRule(parseJSON(`{"events":["x"]}`), bad));
}
