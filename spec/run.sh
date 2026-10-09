#!/bin/sh
# Runs the plugin's specs on KOReader's own LuaJIT.
#
#   spec/run.sh                   all specs (live ones only with FEEDBIN_LIVE=1)
#   spec/run.sh feedbin           specs whose file name contains "feedbin"
#
# KOREADER_DIR: KOReader's install folder, the one holding luajit and
# setupkoenv.lua. Defaults to the macOS app.
# FEEDBIN_LIVE=1 with FEEDBIN_EMAIL and FEEDBIN_PASSWORD also runs
# live_feedbin_spec.lua against the real API (it changes, then restores, the
# read and starred state of one story).

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
KO=${KOREADER_DIR:-/Applications/KOReader.app/Contents/koreader}

if [ ! -x "$KO/luajit" ] || [ ! -f "$KO/setupkoenv.lua" ]; then
    echo "KOReader not found in $KO; set KOREADER_DIR to its install folder." >&2
    exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rssreader-spec.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

filter=${1:-}
failed=0
ran=0

for spec in "$REPO"/spec/*_spec.lua; do
    name=$(basename "$spec" .lua)
    case "$name" in
        *"$filter"*) ;;
        *) continue ;;
    esac

    home="$TMP/$name"
    mkdir -p "$home"
    log="$home/output.log"
    echo "== $name"
    # KOReader prints its own start-up chatter; only the spec lines matter.
    (cd "$KO" && KO_HOME="$home" RSSREADER_REPO="$REPO" ./luajit "$spec") >"$log" 2>&1
    status=$?
    grep '^\[spec\] ' "$log" | sed 's/^\[spec\] /  /'
    if ! grep -q '^\[spec\] done ' "$log"; then
        echo "  crashed before finishing (exit $status); last lines:"
        tail -n 15 "$log" | sed 's/^/    /'
        status=1
    fi
    ran=$((ran + 1))
    [ "$status" -ne 0 ] && failed=$((failed + 1))
done

if [ "$ran" -eq 0 ]; then
    echo "No spec matched '$filter'." >&2
    exit 2
fi
if [ "$failed" -ne 0 ]; then
    echo "$failed of $ran spec file(s) failed."
    exit 1
fi
echo "All $ran spec file(s) passed."
