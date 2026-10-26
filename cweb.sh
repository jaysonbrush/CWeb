#!/usr/bin/env bash
# cweb.sh -- CWeb from Bash (Git Bash). Agents use this instead of raw curl.
#
#   cweb.sh <instance> <client> connect          # once per session; safe to repeat (starts the server if needed)
#   cweb.sh <instance> <client> '<json>'         # one API command, e.g. '{"action":"navigate","url":"https://example.org"}'
#   cweb.sh <instance> <client> - < body.json    # body from stdin (long scripts)
#
# Prints the server's JSON reply. Exit codes: 0 ok, 3 still waiting for approval, 4 denied,
# 5 not connected / key revoked (run connect), 1 other error.
# The key is read from <data folder>\<instance>\clients\<client>.key (data folder: CWEB_DATA, else
# %LOCALAPPDATA%\CWeb) and passed to curl on stdin,
# so it never appears on a command line or in output.

set -u
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf '{"success":false,"error":"%s"}\n' "$2"; exit "$1"; }

[ $# -eq 3 ] || fail 1 "Usage: cweb.sh <instance> <client> connect|'<json>'|-"
inst="$1"; client="$2"; what="$3"
[[ "$inst" =~ ^[a-z0-9-]{1,30}$ ]] || fail 1 "Bad instance name: $inst"
[[ "$client" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || fail 1 "Bad client name: $client (lowercase letters, digits, hyphens)"

if [ "$what" = "connect" ]; then
    exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$dir/CWeb-Client.ps1" -Connect -Instance "$inst" -Client "$client"
fi

# Data folder: the user variable CWEB_DATA (read from the registry, so a change applies at once), else
# %LOCALAPPDATA%\CWeb. Same rule as Get-CWebDataRoot in CWeb-Common.ps1.
root="$(MSYS_NO_PATHCONV=1 reg query 'HKCU\Environment' /v CWEB_DATA 2>/dev/null | tr -d '\r' | sed -n 's/^ *CWEB_DATA *REG_[A-Z_]* *//p')"
[ -n "$root" ] || root="${CWEB_DATA:-}"
[ -n "$root" ] || root="$LOCALAPPDATA\\CWeb"
root="$(cygpath -u "$root")"; root="${root%/}"

data="$root/$inst"

# Port (no jq here): where the server says it listens (server.json; it may have moved off a taken port), else the
# "port" inside this instance's {...}: config.json's overrides, this machine's list, then the repo's defaults.
port_in() { [ -f "$1" ] && tr -d '\r\n' < "$1" | grep -o "\"$inst\"[[:space:]]*:[[:space:]]*{[^}]*}" | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$'; }
port=""
[ -f "$data/server.json" ] && port="$(tr -d '\r\n' < "$data/server.json" | grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
[ -n "$port" ] || port="$(port_in "$root/config.json")"
[ -n "$port" ] || port="$(port_in "$root/instances.json")"
[ -n "$port" ] || port="$(port_in "$dir/instances.json")"
[ -n "$port" ] || fail 1 "No instance '$inst'"

keyfile="$data/clients/$client.key"
[ -f "$keyfile" ] || fail 5 "Not connected as $client. Run: cweb.sh $inst $client connect"

# Body goes through a temp file: no command-line length limit, and quotes survive.
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
if [ "$what" = "-" ]; then cat > "$body"; else printf '%s' "$what" > "$body"; fi

out="$(printf 'X-API-Key: %s\r\n' "$(tr -d '\r\n' < "$keyfile")" |
    curl -s -m 330 -w '\n%{http_code}' -H @- -H 'Content-Type: application/json' --data-binary "@$(cygpath -w "$body")" "http://127.0.0.1:$port/api")"
code="${out##*$'\n'}"
reply="${out%$'\n'*}"

case "$code" in
    200) printf '%s\n' "$reply"; exit 0 ;;
    401) fail 5 "Key for $client was revoked or replaced. Run: cweb.sh $inst $client connect" ;;
    000) fail 1 "CWeb '$inst' isn't answering on port $port. Run: cweb.sh $inst $client connect (it starts the server)" ;;
    *)   printf '%s\n' "$reply"; exit 1 ;;
esac
