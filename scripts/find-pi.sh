# Discover a Pi on a direct ethernet cable and print its address: IPv4
# neighbors first (e.g. a 10.55.0.x lease when the laptop runs a DHCP
# server on the link), then IPv6 link-local all-nodes ping; each candidate
# is verified with an ssh probe as admin@. Progress goes to stderr, only
# the address to stdout, so callers can `pi=$(find-pi)`. Optional
# argument: the wired interface (auto-detected otherwise). Caveat: with no
# DHCP server on the cable the Pi's link only stays up ~2 min after boot
# (NetworkManager thrashes on the leaseless DHCP client) — power-cycle the
# Pi and retry shortly after it boots.

iface="${1:-}"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=4 -o LogLevel=ERROR)

if [ -z "$iface" ]; then
  for d in /sys/class/net/*; do
    dev=$(basename "$d")
    [ "$dev" = lo ] && continue
    [ -e "$d/device" ] || continue    # physical devices only
    [ -d "$d/wireless" ] && continue  # skip wifi
    [ "$(cat "$d/carrier" 2>/dev/null || echo 0)" = 1 ] || continue
    iface="$dev"; break
  done
  [ -n "$iface" ] || { echo "error: no wired interface with a cable plugged in — is the Pi connected and powered?" >&2; exit 1; }
fi
echo ">> looking for the Pi on $iface" >&2

candidates=()
# IPv4 neighbors (the laptop-side DHCP-server trick).
while read -r addr; do candidates+=("$addr"); done \
  < <(ip -4 neigh show dev "$iface" | awk '$NF != "FAILED" { print $1 }')
# IPv6 link-local: ping all-nodes, responders minus ourselves.
own=$(ip -6 addr show dev "$iface" scope link 2>/dev/null \
  | awk '/inet6/ { sub(/\/.*/, "", $2); print $2; exit }')
if [ -n "$own" ]; then
  while read -r addr; do
    [ "$addr" = "$own" ] || candidates+=("$addr%$iface")
  done < <(ping -6 -c 3 -W 1 -I "$iface" ff02::1 2>/dev/null | grep -oE 'fe80:[0-9a-f:]+' | sort -u)
elif [ ${#candidates[@]} -eq 0 ]; then
  echo "error: no IPv6 link-local address on $iface — enable it and retry:" >&2
  echo "  sudo sysctl -w net.ipv6.conf.$iface.addr_gen_mode=0 && sudo ip link set $iface down && sudo ip link set $iface up" >&2
  exit 1
fi
[ ${#candidates[@]} -gt 0 ] || { echo "error: no Pi found on $iface — power-cycle the Pi and re-run within ~2 min of its boot" >&2; exit 1; }

for c in "${candidates[@]}"; do
  echo ">> trying $c" >&2
  if ssh "${ssh_opts[@]}" "admin@$c" true 2>/dev/null; then echo "$c"; exit 0; fi
done
echo "error: ${#candidates[@]} neighbor(s) on $iface but none accepted ssh as admin@ — is this a mailbox Pi? Power-cycle it and re-run within ~2 min of its boot." >&2
exit 1
