/// Embedded vrcd-server: launch one as a child and talk to it over its stdio.
///
/// Exists so somebody can run vrcd without standing a server up first. The
/// child is an ordinary vrcd-server with `--stdio`, so there is one server
/// implementation and one protocol; what embedding changes is only how the
/// two processes find each other. Holding the pipe is the authorization,
/// which is why no port is bound and no secret is agreed on.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module client.embedded;

import core.thread : Thread;
import core.time : Duration, dur, MonoTime;

import std.file : exists, isFile, thisExePath;
import std.path : buildPath, dirName;
import std.process;

import ddlogger;

import client.stream : PipeStream, Stream;

version (Windows)
    private enum string SERVER_EXE = "vrcd_server.exe";
else
    private enum string SERVER_EXE = "vrcd_server";

/// A vrcd-server running as this process's child.
class EmbeddedServer
{
    private ProcessPipes pipes;
    private Pid pid;
    private PipeStream pipeStream;
    private Thread logThread;
    private shared bool stopping;
    private string lastErrorMsg;
    private string binaryPath;

    /// Locate the server binary.
    ///
    /// Beside the client first: the two ship together, and a vrcd installed
    /// somewhere unusual should use its own server rather than whichever one
    /// happens to be on PATH. `override_` is the escape hatch for a layout
    /// this does not predict.
    static string findBinary(string override_ = null)
    {
        if (override_.length > 0)
            return exists(override_) && isFile(override_) ? override_ : null;

        string[] candidates;
        try candidates ~= buildPath(dirName(thisExePath()), SERVER_EXE);
        catch (Exception) {}
        candidates ~= buildPath("..", "server", SERVER_EXE);
        candidates ~= buildPath("server", SERVER_EXE);
        candidates ~= SERVER_EXE;

        foreach (string candidate; candidates)
        {
            try if (exists(candidate) && isFile(candidate))
                return candidate;
            catch (Exception) {}
        }

        // Last resort: let the OS search PATH. A package that installed the
        // two binaries into a bin directory lands here.
        try
        {
            string found = searchPathFor(SERVER_EXE);
            if (found.length > 0)
                return found;
        }
        catch (Exception) {}

        return null;
    }

    /// Launch the server and return the stream that talks to it.
    ///
    /// `listenAddr` non-empty additionally opens a TCP listener, which is
    /// what lets a phone running the web front-end reach this server. Null
    /// leaves the pipe as the only way in.
    Stream start(string overridePath, bool verbose, string listenAddr = null)
    {
        binaryPath = findBinary(overridePath);
        if (binaryPath is null)
        {
            lastErrorMsg = "Could not find " ~ SERVER_EXE ~
                " (install it beside the client, or set the server path in settings)";
            logError("Embedded server: %s", lastErrorMsg);
            return null;
        }

        string[] args = [binaryPath, "run", "--stdio"];
        if (verbose)
            args ~= "--verbose";
        if (listenAddr.length > 0)
            args ~= ["--listen", listenAddr];

        logInfo("Starting embedded server: %s", binaryPath);

        try
        {
            // suppressConsole keeps Windows from flashing a console window
            // for a child of a GUI process.
            pipes = pipeProcess(args,
                Redirect.stdin | Redirect.stdout | Redirect.stderr,
                null, Config.suppressConsole);
            pid = pipes.pid;
        }
        catch (Exception e)
        {
            lastErrorMsg = "Could not start " ~ binaryPath ~ ": " ~ e.msg;
            logError("Embedded server: %s", lastErrorMsg);
            return null;
        }

        // The child's log is this app's log. Draining it is not optional:
        // a full stderr pipe blocks the server on its next log line.
        logThread = new Thread(&drainLog);
        logThread.isDaemon = true;
        logThread.start();

        pipeStream = new PipeStream(pipes.stdout, pipes.stdin);
        return pipeStream;
    }

    /// Whether a child was launched and has not been reaped.
    bool isRunning()
    {
        if (pid is null)
            return false;
        try return tryWait(pid).terminated == false;
        catch (Exception) return false;
    }

    /// Why the last start() failed, or null.
    string lastError() const
    {
        return lastErrorMsg;
    }

    /// Path of the binary that was launched, or null.
    string binary() const
    {
        return binaryPath;
    }

    /// Shut the server down: close its stdin so it exits on EOF, and only
    /// kill it if it will not go.
    ///
    /// The graceful path matters because that is where the server flushes
    /// the VRChat session cookie; killing it instead costs a fresh login,
    /// 2FA included, on the next launch.
    void stop()
    {
        import core.atomic : atomicStore;

        if (pid is null)
            return;

        atomicStore(stopping, true);
        logInfo("Stopping embedded server");

        // Closing the write end is the shutdown signal; the server treats
        // its front-end going away as "nobody left to serve".
        if (pipeStream)
            pipeStream.unblock();

        enum Duration GRACE = dur!"seconds"(5);
        MonoTime deadline = MonoTime.currTime + GRACE;
        while (MonoTime.currTime < deadline)
        {
            try
            {
                if (tryWait(pid).terminated)
                {
                    pid = null;
                    logInfo("Embedded server exited");
                    return;
                }
            }
            catch (Exception)
            {
                pid = null;
                return;
            }
            Thread.sleep(dur!"msecs"(50));
        }

        logWarn("Embedded server did not exit within %s, killing it", GRACE);
        try
        {
            kill(pid);
            wait(pid);
        }
        catch (Exception e)
            logWarn("Embedded server: kill failed: %s", e.msg);
        pid = null;
    }

    /// Forward the child's stderr into this process's log, a line at a time.
    ///
    /// The lines arrive already formatted by the server's own logger, so
    /// they are passed through under a prefix rather than re-formatted: a
    /// timestamp rewritten here would be the time the client read the line,
    /// not the time the server wrote it.
    private void drainLog()
    {
        import core.atomic : atomicLoad;

        try
        {
            foreach (char[] line; pipes.stderr.byLine())
            {
                if (line.length == 0)
                    continue;
                logInfo("[server] %s", line);
            }
        }
        catch (Exception e)
        {
            if (atomicLoad(stopping) == false)
                logWarn("Embedded server: log reader stopped: %s", e.msg);
        }
    }
}

/// Resolve a bare executable name against PATH. Null when not found.
private string searchPathFor(string name)
{
    import std.algorithm.iteration : splitter;
    import std.process : environment;

    string pathVar = environment.get("PATH");
    if (pathVar.length == 0)
        return null;

    version (Windows)
        enum char SEP = ';';
    else
        enum char SEP = ':';

    foreach (string dir; pathVar.splitter(SEP))
    {
        if (dir.length == 0)
            continue;
        string full = buildPath(dir, name);
        try if (exists(full) && isFile(full))
            return full;
        catch (Exception) {}
    }
    return null;
}
