# Configure a MikroTik mAP lite as a station AP: WPA2 Wi-Fi with the given
# SSID/password, and its single ethernet port moved into the LAN bridge so
# the Pi (a plain DHCP client) and the phones share one network, both served
# by the mAP lite's DHCP server. The factory default ("AP router") instead
# puts ether1 on the firewalled WAN side, where the Pi would be NAT-separated
# from the phones and never mDNS-discovered.
#
# Usage: setup-maplite <ssid> <password> [host]
#   Keep ssid/password identical across stations so phones auto-join any of
#   them. host defaults to the factory 192.168.88.1. Prompts for the RouterOS
#   admin password (on the sticker of newer units; empty on older ones).
#
# First-time setup: join the unit's default MikroTik-XXXXXX Wi-Fi (open on
# older units; newer ones print its WPA2 password on the sticker, same place
# as the admin password), then run this. The script is idempotent and applies the Wi-Fi change as the
# single last command, so losing the session at that point (expected when
# you're on the unit's Wi-Fi) cannot leave it half-configured — rejoin the
# new SSID and re-run to verify convergence.
#
# Environment:
#   COUNTRY         RouterOS country name for the radio (default "spain")
#   ADMIN_PASSWORD  also set the RouterOS admin password when given

usage="usage: setup-maplite <ssid> <password> [host]"
ssid="${1:?$usage}"
pw="${2:?$usage}"
host="${3:-192.168.88.1}"
country="${COUNTRY:-spain}"

# Conservative charsets so the values can be spliced into a RouterOS command
# without escaping surprises.
case "$ssid" in
  '' | *[!A-Za-z0-9._-]*)
    echo "SSID must be 1-32 chars of A-Za-z0-9._- ($usage)" >&2
    exit 1
    ;;
esac
[ ${#ssid} -le 32 ] || { echo "SSID must be at most 32 chars" >&2; exit 1; }
case "$pw" in
  *[!A-Za-z0-9._-]*)
    echo "password must be chars of A-Za-z0-9._- ($usage)" >&2
    exit 1
    ;;
esac
{ [ ${#pw} -ge 8 ] && [ ${#pw} -le 63 ]; } || { echo "password must be 8-63 chars (WPA2)" >&2; exit 1; }
case "$country" in
  *[!a-z\ ]*) echo "COUNTRY must be a lowercase RouterOS country name, e.g. 'spain'" >&2; exit 1 ;;
esac

admin_line=""
if [ -n "${ADMIN_PASSWORD:-}" ]; then
  case "$ADMIN_PASSWORD" in
    *[!A-Za-z0-9._-]*) echo "ADMIN_PASSWORD must be chars of A-Za-z0-9._-" >&2; exit 1 ;;
  esac
  admin_line="/user set admin password=\"$ADMIN_PASSWORD\""
fi

# Everything is idempotent; the wlan1 set (the only command that drops Wi-Fi
# clients, and possibly this session) goes last, as one atomic command.
remote_script="$(cat <<EOF
:if ([:len [/interface wireless security-profiles find name=dashchat]] = 0) do={/interface wireless security-profiles add name=dashchat}
/interface wireless security-profiles set [find name=dashchat] mode=dynamic-keys authentication-types=wpa2-psk wpa2-pre-shared-key="$pw"
/ip dhcp-client remove [find interface=ether1]
/interface list member remove [find list=WAN interface=ether1]
:if ([:len [/interface bridge port find interface=ether1]] = 0) do={/interface bridge port add bridge=[/interface bridge get [find] name] interface=ether1}
$admin_line
/interface wireless set wlan1 ssid="$ssid" security-profile=dashchat mode=ap-bridge band=2ghz-b/g/n country="$country" disabled=no
:put "SETUP-COMPLETE"
EOF
)"

echo ">> configuring mAP lite at $host as AP '$ssid' (you'll be asked for its admin password)" >&2
# Legacy key algorithms: RouterOS v6 sshd only offers ssh-rsa, which modern
# OpenSSH rejects by default; harmless on v7. Host keys differ per unit, so
# they are not pinned.
out="$(ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  "admin@$host" "$remote_script")" || true

if [ "$out" = "SETUP-COMPLETE" ]; then
  echo ">> done: '$ssid' is up (WPA2), ether1 bridged into the LAN, DHCP served by the unit" >&2
elif [ "${out%SETUP-COMPLETE}" != "$out" ]; then
  # RouterOS prints nothing on success, so output before the marker = errors.
  echo "$out" >&2
  echo "FAIL: the unit reported the errors above" >&2
  exit 1
else
  [ -z "$out" ] || echo "$out" >&2
  echo ">> no confirmation received — either the connection failed (see any error" >&2
  echo ">> above) or the session dropped while the Wi-Fi change applied, which is" >&2
  echo ">> expected when you're connected over the unit's own Wi-Fi." >&2
  echo ">> Join '$ssid' and re-run; an immediate SETUP-COMPLETE confirms convergence." >&2
fi
