/// Promotion rules: events the user asked to hear about as notifications.
///
/// The server watches the stream whether or not a front-end is open, so a
/// rule kept here fires for an unfriend at 4am; a rule kept in a front-end
/// would only fire while somebody was looking. Rules are persisted in
/// `server_state`. The notifications they produce are not: the events behind
/// them are already in the log.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.promotions;

import core.sync.mutex;
import core.time : MonoTime, Duration, dur;

import std.json;
import std.string : startsWith;

import server.events;
import vrcd.events : feedEventIndex, feedEventTypes;
import vrcd.notifications : NotificationInfo;

/// Notification type the front-ends see on a promoted entry.
enum string PROMOTED_NOTIFICATION_TYPE = "vrcd.promoted";

/// Promoted entries are vrcd's own, so their IDs must never be mistaken for
/// VRChat's (`not_...`): an action on one is answered locally.
enum string PROMOTED_ID_PREFIX = "user_notification_";

/// Bounds on what a front-end may store, since the whole set is re-broadcast
/// to every front-end and walked on every event.
private enum size_t RULES_MAX = 100;
private enum size_t RULE_USERS_MAX = 200;
private enum size_t RULE_NAME_MAX = 64;

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

class PromotionRules
{
    private PromotionRule[] rules;
    private MonoTime[string] lastFired;
    private Mutex mtx;

    this()
    {
        mtx = new Mutex();
    }

    /// Load the persisted set. A value that no longer parses is dropped
    /// rather than fatal: losing the rules beats refusing to start.
    void load(string persisted)
    {
        if (persisted.length == 0)
            return;
        try
        {
            PromotionRule[] parsed;
            if (parseRules(parseJSON(persisted), parsed) is null)
                synchronized (mtx)
                    rules = parsed;
        }
        catch (JSONException) {}
    }

    /// Replace the whole set. Returns an error message, or null on success.
    string replace(JSONValue jrules)
    {
        PromotionRule[] parsed;
        if (string error = parseRules(jrules, parsed))
            return error;
        synchronized (mtx)
        {
            rules = parsed;
            // An edited rule starts fresh rather than inheriting the quiet
            // period of whatever held its ID before.
            lastFired = null;
        }
        return null;
    }

    JSONValue buildRulesJSON()
    {
        synchronized (mtx)
        {
            JSONValue[] items;
            items.reserve(rules.length);
            foreach (ref PromotionRule rule; rules)
                items ~= buildRuleJSON(rule);
            return JSONValue(items);
        }
    }

    JSONValue buildPromotionsMessage()
    {
        return JSONValue([
            "type": JSONValue("promotions"),
            "rules": buildRulesJSON(),
        ]);
    }

    /// The first enabled rule the event satisfies, or null. One event makes
    /// at most one notification, however many rules it satisfies.
    const(PromotionRule)* match(ref const(VRCEvent) event, MonoTime now)
    {
        if (isNotificationEvent(event.type))
            return null;

        string userId = eventUserId(event.content);

        synchronized (mtx)
        {
            foreach (ref PromotionRule rule; rules)
            {
                if (rule.enabled == false)
                    continue;
                if (contains(rule.events, event.typeRaw) == false)
                    continue;
                if (rule.users.length > 0 && contains(rule.users, userId) == false)
                    continue;

                string key = rule.id ~ "\0" ~ userId;
                if (rule.cooldown > 0)
                {
                    if (MonoTime* last = key in lastFired)
                        if (now - *last < dur!"seconds"(rule.cooldown))
                            continue;
                    lastFired[key] = now;
                }
                return &rule;
            }
        }
        return null;
    }
}

/// Build the inbox entry for an event a rule matched. Self-describing, so the
/// front-ends draw it with the code they already have for a v1 notification
/// of a type they do not know: a row with a dismiss.
NotificationInfo buildPromotedNotification(ref const(PromotionRule) rule,
    ref const(VRCEvent) event, long seq)
{
    import std.conv : to;

    NotificationInfo info;
    info.id = PROMOTED_ID_PREFIX ~ seq.to!string;
    info.notificationType = PROMOTED_NOTIFICATION_TYPE;
    info.senderUserId = eventUserId(event.content);
    info.senderName = stringField(event.content, "displayName");
    if (info.senderName.length == 0)
        if (const(JSONValue)* user = "user" in event.content)
            info.senderName = stringField(*user, "displayName");

    size_t i = feedEventIndex(event.typeRaw);
    string label = i == size_t.max ? event.typeRaw : feedEventTypes[i].label;
    info.title = rule.name.length > 0 ? rule.name : label;
    info.message = label;
    string world = stringField(event.content, "worldName");
    if (world.length > 0)
        info.message ~= " — " ~ world;

    info.receivedAtUnix = event.receivedAt.toUnixTime!long();
    return info;
}

private:

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

/// Parse and validate a rule list. All or nothing: a set that half-applied
/// would leave the front-end showing rules the server is not running.
string parseRules(JSONValue jrules, out PromotionRule[] parsed)
{
    if (jrules.type != JSONType.array)
        return "rules must be an array";
    if (jrules.array.length > RULES_MAX)
        return "Too many rules";

    foreach (size_t n, JSONValue jrule; jrules.array)
    {
        if (jrule.type != JSONType.object)
            return "A rule must be an object";

        PromotionRule rule;
        rule.id = stringField(jrule, "id");
        if (rule.id.length == 0 || rule.id.length > RULE_NAME_MAX)
            return "A rule needs an id";
        foreach (ref PromotionRule other; parsed)
            if (other.id == rule.id)
                return "Duplicate rule id: " ~ rule.id;

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
        foreach (string e; rule.events)
        {
            // Promoting a notification to a notification is a duplicate row.
            EventType t = toEventType(e);
            if (isNotificationEvent(t))
                return "Already a notification: " ~ e;
        }

        if (string error = stringList(jrule, "users", rule.users))
            return error;
        if (rule.users.length > RULE_USERS_MAX)
            return "Too many users in one rule";
        foreach (string u; rule.users)
            if (u.startsWith("usr_") == false)
                return "Not a user ID: " ~ u;

        parsed ~= rule;
    }
    return null;
}

string stringList(JSONValue obj, string key, out string[] list)
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

string eventUserId(const(JSONValue) content)
{
    string id = stringField(content, "userId");
    if (id.length > 0)
        return id;
    if (content.type == JSONType.object)
        if (const(JSONValue)* user = "user" in content)
            return stringField(*user, "id");
    return null;
}

bool contains(const(string)[] list, string value)
{
    foreach (string item; list)
        if (item == value)
            return true;
    return false;
}

unittest
{
    import std.datetime.systime : SysTime;

    PromotionRules rules = new PromotionRules();
    assert(rules.replace(parseJSON(`[
        {"id":"a","name":"Unfriends","events":["friend-delete"]},
        {"id":"b","events":["friend-online"],"users":["usr_alice"],"cooldown":60}
    ]`)) is null);

    VRCEvent mk(string type, string userId)
    {
        VRCEvent ev;
        ev.typeRaw = type;
        ev.type = toEventType(type);
        ev.content = JSONValue([ "userId": JSONValue(userId),
            "displayName": JSONValue("Alice") ]);
        ev.receivedAt = SysTime.fromUnixTime(1000);
        return ev;
    }

    MonoTime t0 = MonoTime.currTime;

    // "Any unfriend" matches anyone.
    VRCEvent del = mk("friend-delete", "usr_bob");
    const(PromotionRule)* hit = rules.match(del, t0);
    assert(hit && hit.id == "a");
    NotificationInfo info = buildPromotedNotification(*hit, del, 1);
    assert(info.id == "user_notification_1");
    assert(info.title == "Unfriends");
    assert(info.message == "Friend Remove");
    assert(info.senderUserId == "usr_bob");

    // A user filter holds, and the cooldown is per user.
    VRCEvent bob = mk("friend-online", "usr_bob");
    assert(rules.match(bob, t0) is null);
    VRCEvent alice = mk("friend-online", "usr_alice");
    assert(rules.match(alice, t0));
    assert(rules.match(alice, t0 + dur!"seconds"(30)) is null);
    assert(rules.match(alice, t0 + dur!"seconds"(61)));

    // Validation is all or nothing.
    assert(rules.replace(parseJSON(`[{"id":"c","events":["notification"]}]`)));
    assert(rules.replace(parseJSON(`[{"id":"c","events":["friend-online"],"users":["bob"]}]`)));
    assert(rules.replace(parseJSON(`[{"id":"c","events":[]}]`)));
    assert(rules.replace(parseJSON(`[{"id":"c","events":["x"]},{"id":"c","events":["y"]}]`)));
    assert(rules.match(del, t0));

    // The persisted form round-trips.
    PromotionRules reloaded = new PromotionRules();
    reloaded.load(rules.buildRulesJSON().toString());
    assert(reloaded.buildRulesJSON() == rules.buildRulesJSON());
}
