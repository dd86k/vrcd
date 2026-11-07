#!/bin/sh
#
# Take a screenshot of every client page from a mock scenario, without
# VRChat or a display. One client run per page, each with its own embedded
# vrcd_server --mock, so the pictures do not depend on each other.
#
# Usage: tools/screenshots.sh [-n] [-o DIR] [-s WxH] [-d MS] [-m SCENARIO]
#                             [-l LOG] [-c CLIENT] [NAME=PAGE | PAGE]...
#
# Pages are --page targets. Without any, the whole set below is taken.
#
# Builds both programs first and copies the server beside the client, unless
# -n is given or -c names a client of your own, which needs vrcd_server
# beside it.

set -e

cd "$(dirname "$0")/.."

OUTDIR=screenshots
SIZE=1100x700
DELAY=2500
SCENARIO=server/mock/basic.json
LOG=server/mock/basic_log.txt
CLIENT=client/vrcd_client
BUILD=1

usage() {
    sed -n '7,8p' "$0" | sed 's/^# //'
    exit "$1"
}

while getopts no:s:d:m:l:c:h opt; do
    case $opt in
    n) BUILD=0 ;;
    o) OUTDIR=$OPTARG ;;
    s) SIZE=$OPTARG ;;
    d) DELAY=$OPTARG ;;
    m) SCENARIO=$OPTARG ;;
    l) LOG=$OPTARG ;;
    c) CLIENT=$OPTARG BUILD=0 ;;
    h) usage 0 ;;
    *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ $BUILD -eq 1 ]; then
    dub build -q :server
    dub build -q :client
    if [ ! -e client/vrcd_server ] || [ server/vrcd_server -nt client/vrcd_server ]; then
        cp -p server/vrcd_server client/vrcd_server
    fi
fi

if [ ! -x "$CLIENT" ]; then
    echo "error: no client at $CLIENT (dub build :client)" >&2
    exit 1
fi
if [ ! -x "$(dirname "$CLIENT")/vrcd_server" ]; then
    echo "error: no vrcd_server beside $CLIENT (dub build :server, then copy it)" >&2
    exit 1
fi

# NAME=PAGE, matching basic.json.
if [ $# -eq 0 ]; then
    set -- \
        feed=feed \
        online=online \
        inbox=notifications \
        stuff-gallery=inventory:gallery \
        stuff-icons=inventory:icons \
        stuff-stickers=inventory:stickers \
        stuff-emoji=inventory:emoji \
        stuff-prints=inventory:prints \
        stuff-items=inventory:items \
        tools=tools \
        tools-friends=tools:friendList \
        tools-muted=tools:muteList \
        tools-blocked=tools:blockList \
        tools-groups=tools:groupList \
        tools-rules=tools:promotionRules \
        profile=profile \
        settings=settings \
        user-friend=user:usr_00000000-0000-4000-8000-000000000001 \
        user-stranger=user:usr_00000000-0000-4000-8000-000000000099 \
        group-member=group:grp_00000000-0000-4000-8000-0000000000d1 \
        group-invited=group:grp_00000000-0000-4000-8000-0000000000d3
fi

REPLAY=
if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    REPLAY="--log-replay $LOG"
fi

mkdir -p "$OUTDIR"

# Local times are drawn in the local zone. Fixed, so a picture taken
# anywhere matches.
export TZ=UTC SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

FAILED=0
for spec in "$@"; do
    case $spec in
    *=*) name=${spec%%=*} page=${spec#*=} ;;
    *)   name=$(echo "$spec" | tr ':' '-') page=$spec ;;
    esac
    out="$OUTDIR/$name.png"
    # shellcheck disable=SC2086 # REPLAY is two words or none
    if "$CLIENT" --mock "$SCENARIO" $REPLAY --page "$page" --size "$SIZE" \
        --screenshot "$out" --screenshot-delay "$DELAY" >/dev/null; then
        echo "$out"
    else
        echo "FAILED $name ($page), exit $?" >&2
        FAILED=$((FAILED + 1))
    fi
done

if [ $FAILED -gt 0 ]; then
    echo "$FAILED page(s) failed" >&2
    exit 1
fi
