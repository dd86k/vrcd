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

import server.events;
import vrcd.events : feedEventIndex, feedEventTypes;
import vrcd.notifications : NotificationInfo;
public import vrcd.promotions : PromotionRule;
import vrcd.promotions : parseRule, RULES_MAX;
static import vrcd.promotions;

/// Notification type the front-ends see on a promoted entry.
enum string PROMOTED_NOTIFICATION_TYPE = "vrcd.promoted";

/// Promoted entries are vrcd's own, so their IDs must never be mistaken for
/// VRChat's (`not_...`): an action on one is answered locally.
enum string PROMOTED_ID_PREFIX = "user_notification_";

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
            return vrcd.promotions.buildRulesJSON(rules);
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
        // Synthetics also report your own avatar and profile changes.
        if (isSelfEvent(event.content))
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

/// Parse and validate a rule list. All or nothing: a set that half-applied
/// would leave the front-end showing rules the server is not running.
string parseRules(JSONValue jrules, out PromotionRule[] parsed)
{
    if (jrules.type != JSONType.array)
        return "rules must be an array";
    if (jrules.array.length > RULES_MAX)
        return "Too many rules";

    foreach (JSONValue jrule; jrules.array)
    {
        PromotionRule rule;
        if (string error = parseRule(jrule, rule))
            return error;
        foreach (ref PromotionRule other; parsed)
            if (other.id == rule.id)
                return "Duplicate rule id: " ~ rule.id;
        foreach (string e; rule.events)
        {
            // Promoting a notification to a notification is a duplicate row.
            EventType t = toEventType(e);
            if (isNotificationEvent(t))
                return "Already a notification: " ~ e;
        }
        parsed ~= rule;
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

/// Whether the event is flagged as being about the signed-in user.
bool isSelfEvent(const(JSONValue) content)
{
    if (content.type != JSONType.object)
        return false;
    if (const(JSONValue)* v = "isSelf" in content)
        return v.type == JSONType.true_;
    return false;
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

    // Your own changes never match, even an "anyone" rule.
    assert(rules.replace(parseJSON(`[{"id":"d","events":["avatar-change"]}]`)) is null);
    VRCEvent own = mk("avatar-change", "usr_me");
    own.content["isSelf"] = JSONValue(true);
    assert(rules.match(own, t0) is null);
    VRCEvent other = mk("avatar-change", "usr_bob");
    other.content["isSelf"] = JSONValue(false);
    assert(rules.match(other, t0));
    assert(rules.replace(parseJSON(`[{"id":"a","events":["friend-delete"]}]`)) is null);

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
