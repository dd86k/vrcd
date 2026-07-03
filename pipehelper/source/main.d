/// vrcd-pipehelper: send a vrchat:// launch URI to the running VRChat
/// client via its VRChatURLLaunchPipe named pipe.
///
/// On Linux, the vrcd client runs this executable under Wine inside
/// VRChat's Proton container (via steam-runtime-launch-client), because
/// the pipe only exists inside the game's wineserver.
///
/// Exit codes: 0 = accepted, 1 = rejected or pipe error, 2 = pipe not
/// found (VRChat not running), 3 = usage error.
///
/// Copyright: dd86k <dd@dax.moe>
/// License: BSD-3-Clause-Clear
module main;

import std.stdio : stderr;

version (Windows)
{
    import vrcpipe;

    int main(string[] args)
    {
        if (args.length < 2)
        {
            stderr.writeln("usage: vrcd-pipehelper <vrchat-launch-uri>");
            return 3;
        }

        final switch (sendLaunchUri(args[1])) with (PipeSendStatus)
        {
        case accepted:
            return 0;
        case rejected:
            stderr.writeln("vrcd-pipehelper: VRChat rejected the URI");
            return 1;
        case error:
            stderr.writeln("vrcd-pipehelper: pipe I/O error");
            return 1;
        case notFound:
            stderr.writeln("vrcd-pipehelper: pipe not found, VRChat not running?");
            return 2;
        }
    }
}
else
{
    int main()
    {
        stderr.writeln("vrcd-pipehelper only works as a Windows build, ",
            "run it under Wine inside VRChat's Proton prefix");
        return 3;
    }
}
