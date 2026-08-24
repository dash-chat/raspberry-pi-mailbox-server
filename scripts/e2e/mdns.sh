#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# The mailbox announces itself on _dashchat._tcp.local.: an instance named
# by the mailbox's own endpoint_id must appear, on the right port.

note "mdns: browsing _dashchat._tcp.local. for the mailbox's instance"
eid="$(health_json | jq -r .endpoint_id)"
python3 - "$eid" "$port" <<'PYEOF' || fail "mdns browse did not find the mailbox"
import sys, time
from zeroconf import Zeroconf, ServiceBrowser, ServiceListener

expected, port = sys.argv[1], int(sys.argv[2])
found = {}

class Listener(ServiceListener):
    def add_service(self, zc, type_, name):
        info = zc.get_service_info(type_, name, timeout=3000)
        if info:
            found[name.split(".")[0]] = info.port
    def update_service(self, *args): pass
    def remove_service(self, *args): pass

zc = Zeroconf()
ServiceBrowser(zc, "_dashchat._tcp.local.", Listener())
deadline = time.time() + 15
while time.time() < deadline and found.get(expected) != port:
    time.sleep(0.25)
zc.close()
if found.get(expected) == port:
    print(f">> mdns: ok, instance {expected} announced on port {port}", file=sys.stderr)
    sys.exit(0)
print(f"expected instance {expected} on port {port}; saw: {found or 'nothing'}", file=sys.stderr)
sys.exit(1)
PYEOF
