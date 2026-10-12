/// VRChat launch-URI named pipe client.
///
/// A running VRChat client listens on the `VRChatURLLaunchPipe` named pipe
/// for `vrchat://launch?...` URIs (this is how a second VRChat.exe forwards
/// its command line to the first instance). Writing a URI and reading the
/// one-byte acknowledgement joins the instance directly, with no invite
/// notification round-trip.
///
/// Protocol: connect, write the URI as UTF-8 bytes,
/// read 1 byte back; 0x01 means VRChat accepted the URI.
///
/// This module is shared between the Windows client (in-process) and the
/// vrcd-pipehelper executable (on Linux, run with the game's own Proton Wine
/// so that it lands in VRChat's wineserver).
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module vrcpipe;

version (Windows):

import core.sys.windows.windows;

/// Outcome of a pipe send attempt.
enum PipeSendStatus
{
    accepted, /// VRChat acknowledged the URI (0x01).
    rejected, /// VRChat answered but refused the URI (0x00).
    notFound, /// Pipe does not exist: VRChat is not running.
    error,    /// Connect, write, or read failure.
}

/// Send a `vrchat://launch?...` URI to the running VRChat client.
PipeSendStatus sendLaunchUri(const(char)[] uri)
{
    static immutable const(char)* pipeName = `\\.\pipe\VRChatURLLaunchPipe`;

    HANDLE pipe = INVALID_HANDLE_VALUE;
    // One retry when all pipe instances are busy. 1s connect timeout.
    foreach (attempt; 0 .. 2)
    {
        pipe = CreateFileA(pipeName, GENERIC_READ | GENERIC_WRITE,
            0, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
        if (pipe != INVALID_HANDLE_VALUE)
            break;

        DWORD err = GetLastError();
        if (err == ERROR_FILE_NOT_FOUND)
            return PipeSendStatus.notFound;
        if (err != ERROR_PIPE_BUSY)
            return PipeSendStatus.error;
        if (WaitNamedPipeA(pipeName, 1000) == FALSE)
            return PipeSendStatus.error;
    }
    if (pipe == INVALID_HANDLE_VALUE)
        return PipeSendStatus.error;
    scope(exit) CloseHandle(pipe);

    OVERLAPPED ov;
    ov.hEvent = CreateEventA(null, TRUE, FALSE, null);
    if (ov.hEvent == null)
        return PipeSendStatus.error;
    scope(exit) CloseHandle(ov.hEvent);

    DWORD written;
    BOOL started = WriteFile(pipe, uri.ptr, cast(DWORD) uri.length, null, &ov);
    if (finishIo(pipe, &ov, started, &written) == false || written != uri.length)
        return PipeSendStatus.error;

    ubyte ack;
    DWORD got;
    started = ReadFile(pipe, &ack, 1, null, &ov);
    if (finishIo(pipe, &ov, started, &got) == false || got != 1)
        return PipeSendStatus.error;

    return ack == 1 ? PipeSendStatus.accepted : PipeSendStatus.rejected;
}

// A VRChat that connected but never answers would otherwise hold the caller
// forever. Kept under the 15s the Linux client gives the helper process.
private enum DWORD IO_TIMEOUT_MS = 10_000;

// Wait out an overlapped read or write, cancelling it past IO_TIMEOUT_MS.
private bool finishIo(HANDLE pipe, OVERLAPPED* ov, BOOL started, DWORD* count)
{
    if (started == FALSE && GetLastError() != ERROR_IO_PENDING)
        return false;
    if (WaitForSingleObject(ov.hEvent, IO_TIMEOUT_MS) != WAIT_OBJECT_0)
    {
        CancelIo(pipe); // same thread that issued it
        // The cancel lands asynchronously; ov must outlive it.
        GetOverlappedResult(pipe, ov, count, TRUE);
        return false;
    }
    return GetOverlappedResult(pipe, ov, count, FALSE) != FALSE;
}
