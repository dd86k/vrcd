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
            0, null, OPEN_EXISTING, 0, null);
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

    DWORD written;
    if (WriteFile(pipe, uri.ptr, cast(DWORD) uri.length, &written, null) == FALSE ||
        written != uri.length)
        return PipeSendStatus.error;

    ubyte ack;
    DWORD got;
    if (ReadFile(pipe, &ack, 1, &got, null) == FALSE || got != 1)
        return PipeSendStatus.error;

    return ack == 1 ? PipeSendStatus.accepted : PipeSendStatus.rejected;
}
