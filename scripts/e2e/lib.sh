# Shared preamble for the e2e tests, sourced by every test script in this
# folder: resolve the Pi under test, build the API base URL, and define the
# helpers tests share.
#
# Environment:
#   PI    skip discovery and use this address (IPv6 link-local like
#         fe80::1%enp0s31f6 works; so does 127.0.0.1 against a local server
#         for a smoke run). The e2e-test runner discovers once and exports it.
#   PORT  mailbox HTTP port (default 3000)

port="${PORT:-3000}"

note() { echo ">> $*" >&2; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pi="${PI:-$(find-pi)}"
# Bracket IPv6 hosts for URLs; a link-local zone's % must be %25 in a URL.
host="$pi"
case "$pi" in *:*) host="[${pi/\%/%25}]" ;; esac
base="http://$host:$port"
note "mailbox under test: $base"

hcurl() { curl -sS -m 10 "$@"; }

ssh_pi() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
    "admin@$pi" "$@"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

health_json() { hcurl "$base/health"; }

# Store one blip and read it back. $1 = topic, $2 = sequence number.
blip_roundtrip() {
  topic="$1"
  seq_num="$2"
  payload="$(head -c 32 /dev/urandom | base64 -w0)"
  req="$(jq -n --arg t "$topic" --arg s "$seq_num" --arg p "$payload" \
    '{blips: {($t): {"e2e-author": {($s): $p}}}}')"
  code="$(hcurl -o /dev/null -w '%{http_code}' -X POST "$base/blips/store" \
    -H 'content-type: application/json' -d "$req")"
  [ "$code" = 201 ] || fail "blips/store returned HTTP $code (topic $topic seq $seq_num)"

  get_req="$(jq -n --arg t "$topic" --argjson w "$((seq_num - 1))" \
    '{topics: {($t): {"e2e-author": $w}}}')"
  hcurl -X POST "$base/blips/get" -H 'content-type: application/json' -d "$get_req" \
    | jq -e --arg t "$topic" --arg s "$seq_num" --arg p "$payload" \
      '.blips_by_topic[$t].blips["e2e-author"][$s] == $p' > /dev/null \
    || fail "blips/get did not return the stored blip (topic $topic seq $seq_num)"
}
