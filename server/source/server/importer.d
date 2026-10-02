/// Which periods an import may fill: the ones vrcd did not record itself.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.importer;

import std.algorithm.sorting : sort;
import std.datetime.systime : SysTime;
import core.time : Duration, dur;

import server.database : TimeRange, ConnectionMark, toISO;

/// Where one recording could have started or stopped sooner than the log
/// says: the log is written around the socket, not around the first and last
/// frame through it.
enum Duration RECORDING_MARGIN = dur!"seconds"(60);

/// A timestamp in the stored format, or null when it is not one.
string normalizeTime(string at)
{
    try return toISO(SysTime.fromISOExtString(at));
    catch (Exception) return null;
}

/// `at` moved by `by`. `at` must already be in the stored format.
string shiftTime(string at, Duration by)
{
    return toISO(SysTime.fromISOExtString(at) + by);
}

/// Spans vrcd was recording, widened by `margin` at both edges.
///
/// A connect with no disconnect after it is a server that went down without
/// saying so; that span ends at the last event recorded before the next
/// connect, which is the last moment anything was provably being written.
TimeRange[] recordedRanges(ConnectionMark[] log,
    scope string delegate(string from, string to) lastLiveEventIn,
    string now, Duration margin = RECORDING_MARGIN)
{
    TimeRange[] spans;
    string open;

    void close(string end)
    {
        spans ~= TimeRange(shiftTime(open, -margin), shiftTime(end, margin));
        open = null;
    }

    foreach (ref ConnectionMark mark; log)
    {
        if (mark.connected)
        {
            if (open.length)
            {
                string last = lastLiveEventIn(open, mark.at);
                close(last.length ? last : open);
            }
            open = mark.at;
        }
        else if (open.length)
            close(mark.at);
    }
    if (open.length)
        close(now);

    return spans;
}

/// Sort and merge overlapping or touching spans.
TimeRange[] mergeRanges(TimeRange[] spans)
{
    TimeRange[] sorted = spans.dup;
    sort!((a, b) => a.from < b.from)(sorted);

    TimeRange[] merged;
    foreach (ref TimeRange span; sorted)
    {
        if (merged.length && span.from <= merged[$ - 1].to)
        {
            if (span.to > merged[$ - 1].to)
                merged[$ - 1].to = span.to;
        }
        else
            merged ~= span;
    }
    return merged;
}

/// What is left of `[floor, now)` once `covered` is taken out. An empty
/// `floor` is the beginning of time.
TimeRange[] uncovered(TimeRange[] covered, string floor, string now)
{
    TimeRange[] gaps;
    string cursor = floor;
    foreach (ref TimeRange span; mergeRanges(covered))
    {
        if (span.to <= cursor)
            continue;
        if (span.from >= now)
            break;
        if (span.from > cursor)
            gaps ~= TimeRange(cursor, span.from);
        cursor = span.to;
    }
    if (cursor < now)
        gaps ~= TimeRange(cursor, now);
    return gaps;
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
    assert(normalizeTime("2026-09-26T12:34:56.1234567Z") == "2026-09-26T12:34:56.123Z");
    assert(normalizeTime("2026-09-26T12:34:56Z") == "2026-09-26T12:34:56.000Z");
    assert(normalizeTime("2026-09-26T14:34:56+02:00") == "2026-09-26T12:34:56.000Z");
    assert(normalizeTime("yesterday") is null);
    assert(shiftTime("2026-09-26T00:00:30.000Z", -RECORDING_MARGIN) == "2026-09-25T23:59:30.000Z");
}

unittest
{
    enum string T1 = "2026-01-01T01:00:00.000Z";
    enum string T2 = "2026-01-01T02:00:00.000Z";
    enum string T3 = "2026-01-01T03:00:00.000Z";
    enum string T4 = "2026-01-01T04:00:00.000Z";
    enum string T5 = "2026-01-01T05:00:00.000Z";
    enum string LAST = "2026-01-01T03:30:00.000Z";

    string lastLive(string from, string to)
    {
        return from == T3 && to == T4 ? LAST : null;
    }

    // Recorded T1..T2 cleanly; connected at T3 and went down unannounced
    // (last event at LAST); connected again at T4 and still is.
    ConnectionMark[] log = [
        ConnectionMark(T1, true), ConnectionMark(T2, false),
        ConnectionMark(T3, true),
        ConnectionMark(T4, true),
    ];
    TimeRange[] rec = recordedRanges(log, &lastLive, T5, Duration.zero);
    assert(rec == [ TimeRange(T1, T2), TimeRange(T3, LAST), TimeRange(T4, T5) ]);

    // A disconnect with nothing open is ignored.
    assert(recordedRanges([ ConnectionMark(T1, false) ], &lastLive, T5).length == 0);

    // Before the first recording, and between the recordings.
    assert(uncovered(rec, "", T5) == [
        TimeRange("", T1), TimeRange(T2, T3), TimeRange(LAST, T4),
    ]);

    // A floor (the prune cutoff) clips the history, and overlapping spans
    // (an earlier import over a recording's margin) merge.
    TimeRange[] covered = rec ~ TimeRange("2026-01-01T01:30:00.000Z", "2026-01-01T02:30:00.000Z");
    assert(uncovered(covered, "2026-01-01T01:15:00.000Z", T5) == [
        TimeRange("2026-01-01T02:30:00.000Z", T3), TimeRange(LAST, T4),
    ]);

    // Nothing recorded at all: everything before now.
    assert(uncovered(null, "", T5) == [ TimeRange("", T5) ]);

    assert(findRange([ TimeRange("", T1), TimeRange(T2, T3) ], T2) == 1);
    assert(findRange([ TimeRange("", T1), TimeRange(T2, T3) ], T1) == -1);
    assert(findRange([ TimeRange("", T1) ], "2025-06-01T00:00:00.000Z") == 0);
}
