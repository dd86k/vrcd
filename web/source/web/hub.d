/// Fan-out of state snapshots and feed events to connected browsers.
///
/// One thread per browser, and that thread only ever sends: it parks on a
/// condition variable until something moves, then writes. This is deliberate.
/// ddhttpd's `send_frame` writes the frame header and payload as two separate
/// socket writes with no lock, so two threads sending on one connection would
/// interleave and corrupt the stream. Keeping every write on the connection's
/// own thread sidesteps that entirely.
///
/// The timed wait doubles as a heartbeat: on timeout we send a ping, which is
/// how a browser that vanished without a close frame gets noticed.
///
/// Two channels share the wakeup. State is a snapshot, so only the latest one
/// matters and a generation counter is enough. The feed is a log, so it keeps
/// a bounded ring and each connection sends the slice it has not seen; a
/// browser that falls behind the ring gets a fresh reset instead of a gap.
///
/// If the page ever needs to send messages up this socket, this needs a reader
/// thread and a per-connection send mutex. Browser-to-server actions go over
/// plain HTTP instead (see the join endpoint in app.d), which keeps that out.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module web.hub;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.time : Duration, dur;
import std.array : join;

import ddhttpd;
import ddlogger;

/// How long a connection thread waits before sending a keepalive ping.
private enum Duration HEARTBEAT = dur!"seconds"(30);

/// How many feed events to retain for late joiners.
private enum size_t FEED_RING = 500;

/// Broadcasts state snapshots and feed events to every connected browser.
class Hub
{
    this()
    {
        this.mutex = new Mutex();
        this.cond = new Condition(mutex);
    }

    /// Publish a new state snapshot, replacing the previous one.
    void publishState(string snapshot)
    {
        synchronized (mutex)
        {
            statePayload = snapshot;
            ++stateGeneration;
            cond.notifyAll();
        }
    }

    /// Publish feed entries, each already encoded as a JSON object. A reset
    /// replaces the browser's feed; otherwise the entries are appended.
    void publishFeed(string[] encoded, bool reset)
    {
        synchronized (mutex)
        {
            if (reset)
            {
                feedRing = encoded.dup;
                ++feedEpoch;
            }
            else
            {
                feedRing ~= encoded;
            }

            feedSeq += encoded.length;

            if (feedRing.length > FEED_RING)
                feedRing = feedRing[$ - FEED_RING .. $];

            cond.notifyAll();
        }
    }

    /// Serve one browser connection. Runs on its own thread for the lifetime
    /// of the socket; returns when the browser goes away.
    void serve(WebSocketConnection conn)
    {
        // Start behind both channels so the browser is brought fully up to
        // date on connect instead of waiting for the next change.
        ulong seenState;
        ulong seenEpoch;
        ulong seenSeq;
        bool primed;

        logInfo("WebSocket client connected");
        scope(exit) logInfo("WebSocket client disconnected");

        while (conn.isClosed == false)
        {
            string stateMessage;
            string feedMessage;
            bool heartbeat;

            synchronized (mutex)
            {
                bool stale = seenState != stateGeneration
                    || seenEpoch != feedEpoch
                    || seenSeq != feedSeq
                    || primed == false;

                if (stale == false)
                    heartbeat = cond.wait(HEARTBEAT) == false;

                if (seenState != stateGeneration)
                {
                    stateMessage = statePayload;
                    seenState = stateGeneration;
                }

                // How far behind this browser is. seenSeq only ever moves to
                // feedSeq and only under this lock, so it never leads.
                ulong behind = feedSeq - seenSeq;

                // A new epoch, a first look, or being further behind than the
                // ring can still account for all mean the same thing: send what
                // we have as a replacement rather than patching the browser's
                // copy. Asking the ring directly is the whole test -- what can
                // still be produced is exactly what it is still holding.
                if (seenEpoch != feedEpoch || primed == false || behind > feedRing.length)
                {
                    feedMessage = feedFrame(feedRing, true);
                    seenEpoch = feedEpoch;
                    seenSeq = feedSeq;
                    primed = true;
                }
                else if (behind > 0)
                {
                    // Sequence numbers are ulong so they never wrap, but a ring
                    // index is size_t, which is 32-bit on some targets. The
                    // branch above just established behind <= feedRing.length,
                    // so this narrows a value already bounded by a length.
                    feedMessage = feedFrame(feedRing[$ - cast(size_t)behind .. $], false);
                    seenSeq = feedSeq;
                }
            }

            // Outside the lock: a slow socket must not stall the publisher.
            try
            {
                if (stateMessage.length > 0)
                    conn.sendText(stateMessage);
                if (feedMessage.length > 0)
                    conn.sendText(feedMessage);
                if (stateMessage.length == 0 && feedMessage.length == 0 && heartbeat)
                    conn.sendPing();
            }
            catch (Exception ex)
            {
                logDebugging("WebSocket send failed: %s", ex.msg);
                return;
            }
        }
    }

private:
    Mutex mutex;
    Condition cond;

    /// Bumped on every state publish; connection threads compare against
    /// their own last-seen value rather than being handed a queue each.
    ulong stateGeneration;
    string statePayload;

    /// Total entries ever published. Connections track their own last-seen
    /// value; the difference against the ring length is what they are owed.
    ulong feedSeq;
    /// Bumped when the feed is replaced rather than extended.
    ulong feedEpoch;
    string[] feedRing;
}

/// Wrap encoded feed entries in their envelope. The entries are already JSON
/// objects, so this is a string join rather than a re-serialization.
private string feedFrame(string[] entries, bool reset)
{
    return `{"type":"feed","reset":` ~ (reset ? "true" : "false") ~
        `,"events":[` ~ entries.join(",") ~ `]}`;
}
