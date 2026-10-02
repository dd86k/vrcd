/// Event timestamps and spans of them, as vrcd-server stores them.
///
/// Fixed-width UTC with milliseconds, `YYYY-MM-DDTHH:MM:SS.sssZ`, which is
/// also what VRCX writes, so text order is time order on both sides.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcd.timerange;

import std.datetime.systime : SysTime;
import std.format : format;

/// A half-open span of time, `[from, to)`, in the stored timestamp format.
/// An empty `from` is the beginning of time.
struct TimeRange
{
    string from;
    string to;
}

/// `t` in the stored format. Sub-millisecond precision is truncated.
string toISO(SysTime t)
{
    SysTime u = t.toUTC();
    return format!"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"(
        u.year, cast(int) u.month, u.day, u.hour, u.minute, u.second,
        u.fracSecs.total!"msecs");
}

/// An ISO 8601 timestamp in the stored format, or null when it is not one.
string normalizeTime(string at)
{
    try return toISO(SysTime.fromISOExtString(at));
    catch (Exception) return null;
}

/// Index of the span holding `at`, or -1.
ptrdiff_t findRange(const(TimeRange)[] spans, string at)
{
    foreach (size_t i, ref const(TimeRange) span; spans)
        if (at >= span.from && at < span.to)
            return i;
    return -1;
}

unittest
{
    import std.datetime.date : DateTime;
    import std.datetime.timezone : UTC;
    import core.time : msecs, hnsecs;

    SysTime t = SysTime(DateTime(2026, 9, 26, 12, 34, 56), UTC());
    assert(toISO(t) == "2026-09-26T12:34:56.000Z");
    assert(toISO(t + msecs(5) + hnsecs(9)) == "2026-09-26T12:34:56.005Z");

    assert(normalizeTime("2026-09-26T12:34:56.1234567Z") == "2026-09-26T12:34:56.123Z");
    assert(normalizeTime("2026-09-26T12:34:56Z") == "2026-09-26T12:34:56.000Z");
    assert(normalizeTime("2026-09-26T14:34:56+02:00") == "2026-09-26T12:34:56.000Z");
    assert(normalizeTime("yesterday") is null);

    enum string T1 = "2026-01-01T01:00:00.000Z";
    enum string T2 = "2026-01-01T02:00:00.000Z";
    enum string T3 = "2026-01-01T03:00:00.000Z";
    assert(findRange([ TimeRange("", T1), TimeRange(T2, T3) ], T2) == 1);
    assert(findRange([ TimeRange("", T1), TimeRange(T2, T3) ], T1) == -1);
    assert(findRange([ TimeRange("", T1) ], "2025-06-01T00:00:00.000Z") == 0);
}
