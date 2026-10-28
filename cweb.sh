#!/usr/bin/env bash
# cweb.sh -- CWeb from Bash (Git Bash). Agents use this instead of raw curl.
#
#   cweb.sh '<json>'                  # one command in the work instance, e.g. '{"action":"navigate","tab":"tickets","url":"https://example.org"}'
#   cweb.sh - < body.json             # body from stdin (long scripts)
#   cweb.sh <instance> '<json>'|-     # another instance (personal), only when the user says so
#
# If CWeb isn't running, this starts it first (Chrome opens with its tabs and sign-ins) and then runs the command.
# Nothing to connect or approve: the key is read from <data folder>\cweb.key (only this Windows user can read it) and
# passed to curl on stdin, so it never appears on a command line or in output.
# Old forms still work: cweb.sh <client> connect, cweb.sh <instance> <client> connect|'<json>'|-.
# Prints the server's JSON reply. Exit codes: 0 ok (check "success"), 3 CWeb is still starting (run it again), 1 error.

set -u
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf '{"success":false,"error":"%s"}\n' "$2"; exit "$1"; }

inst="work"; client=""; what=""
case $# in
    1) what="$1" ;;
    2) if [ "$2" = "connect" ]; then client="$1"; what="connect"; else inst="$1"; what="$2"; fi ;;
    3) inst="$1"; client="$2"; what="$3" ;;
    *) fail 1 "Usage: cweb.sh '<json>' | cweb.sh - < body.json | cweb.sh <instance> '<json>'" ;;
esac
[[ "$inst" =~ ^[a-z0-9-]{1,30}$ ]] || fail 1 "Bad instance name: $inst"
[[ -z "$client" || "$client" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$ ]] || client=""

ensure() {
    # Starts the instance if it isn't running; prints its JSON status. Exit 0 running, 3 starting, 1 error.
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$dir/CWeb-Client.ps1")" -Ensure -Instance "$inst" | tail -n 1
    return "${PIPESTATUS[0]}"
}

if [ "$what" = "connect" ]; then
    out="$(ensure)"; rc=$?
    printf '%s\n' "$(printf '%s' "$out" | sed 's/"status":"running"/"status":"connected"/')"
    exit "$rc"
fi

# Data folder: the user variable CWEB_DATA (read from the registry, so a change applies at once), else
# %USERPROFILE%\CWebData (or the old %LOCALAPPDATA%\CWeb while only that exists). Same rule as Get-CWebDataRoot in
# CWeb-Common.ps1.
root="$(MSYS_NO_PATHCONV=1 reg query 'HKCU\Environment' /v CWEB_DATA 2>/dev/null | tr -d '\r' | sed -n 's/^ *CWEB_DATA *REG_[A-Z_]* *//p')"
[ -n "$root" ] || root="${CWEB_DATA:-}"
if [ -z "$root" ]; then
    root="$USERPROFILE\\CWebData"
    [ ! -d "$(cygpath -u "$root")" ] && [ -d "$(cygpath -u "$LOCALAPPDATA\\CWeb")" ] && root="$LOCALAPPDATA\\CWeb"
fi
root="$(cygpath -u "$root")"; root="${root%/}"
data="$root/$inst"
keyfile="$root/cweb.key"

# Port (no jq here): where the server says it listens (server.json; it may have moved off a taken port), else the
# "port" inside this instance's {...}: config.json's overrides, this machine's list, then the repo's defaults.
port_in() { [ -f "$1" ] && tr -d '\r\n' < "$1" | grep -o "\"$inst\"[[:space:]]*:[[:space:]]*{[^}]*}" | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$'; }
find_port() {
    port=""
    [ -f "$data/server.json" ] && port="$(tr -d '\r\n' < "$data/server.json" | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
    [ -n "$port" ] || port="$(port_in "$root/config.json")"
    [ -n "$port" ] || port="$(port_in "$root/instances.json")"
    [ -n "$port" ] || port="$(port_in "$dir/instances.json")"
    [ -n "$port" ] || fail 1 "No instance '$inst'"
}

# Body goes through a temp file: no command-line length limit, and quotes survive.
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
if [ "$what" = "-" ]; then cat > "$body"; else printf '%s' "$what" > "$body"; fi

send() {
    out="$( { printf 'X-CWeb-Key: %s\r\n' "$(tr -d '\r\n' < "$keyfile" 2>/dev/null)"; [ -n "$client" ] && printf 'X-CWeb-Client: %s\r\n' "$client"; } |
        curl -s -m 330 -w '\n%{http_code}' -H @- -H 'Content-Type: application/json' --data-binary "@$(cygpath -w "$body")" "http://127.0.0.1:$port/api")"
    code="${out##*$'\n'}"
    reply="${out%$'\n'*}"
}

find_port
if [ -f "$keyfile" ]; then send; else code="000"; fi
if [ "$code" = "000" ]; then
    # Not running (or not answering yet): start it, then try once more.
    st="$(ensure)"; rc=$?
    [ "$rc" -eq 0 ] || { printf '%s\n' "$st"; exit "$rc"; }
    find_port
    send
fi

case "$code" in
    200) printf '%s\n' "$reply"; exit 0 ;;
    000) fail 1 "CWeb '$inst' isn't answering on port $port. See its status page: http://127.0.0.1:$port/status" ;;
    *)   printf '%s\n' "$reply"; exit 1 ;;
esac
