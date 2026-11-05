/// vrcd-pipehelper: send a vrchat:// launch URI to the running VRChat
/// client via its VRChatURLLaunchPipe named pipe.
///
/// On Linux, the vrcd client runs this executable with the Proton build
/// VRChat is running under and with the game's WINEPREFIX, which attaches it
/// to the game's wineserver, because the pipe only exists in there.
///
/// Built as betterC with its own entry point and no C runtime, so it links
/// against kernel32 and shell32 alone and can be cross-built from Linux (see
/// build.sh). Nothing here may pull in druntime or the CRT.
///
/// Exit codes: 0 = accepted, 1 = rejected or pipe error, 2 = pipe not
/// found (VRChat not running), 3 = usage error.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module main;

version (Windows)
{
    import core.sys.windows.windows;
    import vrcpipe;

    extern (Windows) LPWSTR* CommandLineToArgvW(LPCWSTR, int*) nothrow @nogc;

    /// Process entry point, named after the CRT one so linkers pick it by default.
    extern (Windows) void mainCRTStartup()
    {
        ExitProcess(run());
    }

    /// Send the URI given as first argument, returning the exit code.
    private uint run()
    {
        int argc;
        LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        if (argv == null || argc < 2)
        {
            warn("usage: vrcd-pipehelper <vrchat-launch-uri>\n");
            return 3;
        }

        const(char)[] uri = toUtf8(argv[1]);
        if (uri == null)
        {
            warn("vrcd-pipehelper: bad URI argument\n");
            return 3;
        }

        final switch (sendLaunchUri(uri)) with (PipeSendStatus)
        {
        case accepted:
            return 0;
        case rejected:
            warn("vrcd-pipehelper: VRChat rejected the URI\n");
            return 1;
        case error:
            warn("vrcd-pipehelper: pipe I/O error\n");
            return 1;
        case notFound:
            warn("vrcd-pipehelper: pipe not found, VRChat not running?\n");
            return 2;
        }
    }

    /// UTF-8 copy of wide string `s` on the process heap, or null.
    private const(char)[] toUtf8(LPCWSTR s)
    {
        int len = WideCharToMultiByte(CP_UTF8, 0, s, -1, null, 0, null, null);
        if (len <= 1)
            return null;
        char* buf = cast(char*) HeapAlloc(GetProcessHeap(), 0, len);
        if (buf == null)
            return null;
        if (WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, len, null, null) != len)
            return null;
        return buf[0 .. len - 1]; // without the terminator
    }

    /// Fill `n` bytes at `dst` with `c`, for the zero-inits compilers lower to
    /// memset calls. Volatile stores keep the loop from being lowered to itself.
    extern (C) void* memset(void* dst, int c, size_t n)
    {
        import core.volatile : volatileStore;

        ubyte* p = cast(ubyte*) dst;
        foreach (i; 0 .. n)
            volatileStore(p + i, cast(ubyte) c);
        return dst;
    }

    /// Write `msg` to stderr.
    private void warn(string msg)
    {
        DWORD n;
        WriteFile(GetStdHandle(STD_ERROR_HANDLE), msg.ptr, cast(DWORD) msg.length, &n, null);
    }
}
else
{
    import core.stdc.stdio : fputs, stderr;

    extern (C) int main()
    {
        fputs("vrcd-pipehelper only works as a Windows build, "~
            "run it under Wine inside VRChat's Proton prefix\n", stderr);
        return 3;
    }
}
