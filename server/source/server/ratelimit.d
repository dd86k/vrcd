/// VRChat API rate limit tracker
///
/// Reads X-RateLimit-Remaining, X-RateLimit-Reset, and Retry-After
/// headers from API responses and gates outgoing requests to avoid
/// hitting or exceeding the limit.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module server.ratelimit;

import core.thread : Thread;
import core.time : Duration, dur;

import std.conv : to;
import std.datetime.systime : Clock;

import ddlogger;
import ddcurl : HTTPResponse;

/// Tracks VRChat API rate-limit state derived from response headers.
class RateLimitTracker
{
    /// Update state from response headers. Call after every VRChat API request.
    void update(HTTPResponse resp)
    {
        // Parse rate-limit headers.
        string* remaining = "X-RateLimit-Remaining" in resp.headers;
        string* reset     = "X-RateLimit-Reset" in resp.headers;
        string* limit     = "X-RateLimit-Limit" in resp.headers;
        string* retryStr  = "Retry-After" in resp.headers;

        if (limit)
        {
            try rateLimitMax = (*limit).to!int;
            catch (Exception) {}
        }

        if (remaining)
        {
            try rateLimitRemaining = (*remaining).to!int;
            catch (Exception) {}
        }

        if (reset)
        {
            try rateLimitReset = (*reset).to!long;
            catch (Exception) {}
        }

        logTrace("ratelimit update: code=%d remaining=%d/%d reset=%d",
            resp.code, rateLimitRemaining, rateLimitMax, rateLimitReset);

        if (resp.code == 429)
        {
            long retryAfter = 60; // Default: wait 60s if no header.

            if (retryStr)
            {
                try retryAfter = (*retryStr).to!long;
                catch (Exception) {}
            }

            // Using long avoids type dependence (time_t) and conversion issues
            long now = Clock.currTime.toUnixTime!long();
            blockedUntil = now + retryAfter;
            rateLimitRemaining = 0;

            logWarn("Rate limited by VRChat API! Retry after %d seconds (until %d)", retryAfter, blockedUntil);
        }

        // Log when approaching the limit.
        if (rateLimitRemaining >= 0 && rateLimitMax > 0 && rateLimitRemaining <= rateLimitMax / 5)
        {
            logWarn("VRChat API rate limit low: %d/%d remaining (resets at %d)",
                rateLimitRemaining, rateLimitMax, rateLimitReset);
        }
    }

    /// Wait if currently rate-limited. Returns true if we had to wait.
    bool waitIfNeeded()
    {
        long now = Clock.currTime.toUnixTime!long();
        if (blockedUntil <= now)
            return false;

        long waitSecs = blockedUntil - now;
        logWarn("Rate limited, waiting %d seconds before next API call...", waitSecs);

        // Sleep in 1-second increments so we stay responsive.
        while (blockedUntil > Clock.currTime.toUnixTime())
        {
            static immutable Duration TIMEOUT = dur!"seconds"(1);
            Thread.sleep(TIMEOUT);
        }

        return true;
    }

    /// Whether we are currently blocked due to a 429 response.
    bool isBlocked()
    {
        return blockedUntil > Clock.currTime.toUnixTime();
    }

    /// Current remaining requests, or -1 if unknown.
    int getRemaining()
    {
        return rateLimitRemaining;
    }

    /// Maximum requests per window, or -1 if unknown.
    int getMax()
    {
        return rateLimitMax;
    }

    /// Unix timestamp when the rate-limit window resets, or 0 if unknown.
    long getReset()
    {
        return rateLimitReset;
    }

private:
    int rateLimitRemaining = -1;
    int rateLimitMax = -1;
    long rateLimitReset;
    long blockedUntil;
}
