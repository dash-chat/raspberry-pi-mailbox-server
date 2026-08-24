# Configure a MikroTik mAP lite as a station AP: WPA2 Wi-Fi with the given
# SSID/password, and its single ethernet port moved into the LAN bridge so
# the Pi (a plain DHCP client) and the phones share one network, both served
# by the mAP lite's DHCP server. The factory default ("AP router") instead
# puts ether1 on the firewalled WAN side, where the Pi would be NAT-separated
# from the phones and never mDNS-discovered — which is also why this script
# talks to the unit over its Wi-Fi, not the cable.
#
# Usage: setup-maplite <unit-ssid> <unit-wifi-password> <ssid> <password> [host]
#   unit-ssid/unit-wifi-password: the unit's CURRENT Wi-Fi — factory units
#     broadcast MikroTik-XXXXXX (WPA2 password on the sticker of newer units;
#     pass '' for the open Wi-Fi of older ones).
#   ssid/password: the TARGET network to configure. Keep them identical
#     across stations so phones auto-join any of them.
#   host defaults to the factory 192.168.88.1.
#
# The script joins the unit's Wi-Fi (via NetworkManager), applies the config
# over ssh (prompting for the unit's admin password — on the sticker of newer
# units, empty on older), then rejoins the target SSID and re-applies to
# confirm convergence: everything is idempotent, and the Wi-Fi-affecting
# change is the single last command, so a dropped session can't leave the
# unit half-configured. On exit (success or failure) it reconnects this
# machine to whatever Wi-Fi it was on before.
#
# Environment:
#   COUNTRY         RouterOS country name for the radio (default "spain")
#   ADMIN_PASSWORD  also set the RouterOS admin password when given

usage="usage: setup-maplite <unit-ssid> <unit-wifi-password> <ssid> <password> [host]"
unit_ssid="${1:?$usage}"
unit_pw="${2?$usage}" # may be empty: older units' default Wi-Fi is open
ssid="${3:?$usage}"
pw="${4:?$usage}"
host="${5:-192.168.88.1}"
country="${COUNTRY:-spain}"

note() { echo ">> $*" >&2; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Conservative charsets so the values can be spliced into a RouterOS command
# without escaping surprises.
valid_chars() { case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }
valid_chars "$unit_ssid" && [ -n "$unit_ssid" ] || fail "unit-ssid must be chars of A-Za-z0-9._-"
valid_chars "$unit_pw" || fail "unit-wifi-password must be chars of A-Za-z0-9._- (or '' when open)"
valid_chars "$ssid" && [ -n "$ssid" ] && [ ${#ssid} -le 32 ] || fail "ssid must be 1-32 chars of A-Za-z0-9._-"
valid_chars "$pw" && [ ${#pw} -ge 8 ] && [ ${#pw} -le 63 ] || fail "password must be 8-63 chars of A-Za-z0-9._- (WPA2)"
case "$country" in
  *[!a-z\ ]*) fail "COUNTRY must be a lowercase RouterOS country name, e.g. 'spain'" ;;
esac

admin_line=""
if [ -n "${ADMIN_PASSWORD:-}" ]; then
  valid_chars "$ADMIN_PASSWORD" || fail "ADMIN_PASSWORD must be chars of A-Za-z0-9._-"
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

# Whatever Wi-Fi this machine is on now, go back to it when we're done —
# configuring the unit shouldn't leave the laptop stranded off its network.
prev_wifi="$(nmcli -t -f NAME,TYPE connection show --active 2> /dev/null \
  | awk -F: '$2 == "802-11-wireless" { print $1; exit }')"
restore_wifi() {
  [ -n "$prev_wifi" ] || return 0
  note "reconnecting to previous Wi-Fi '$prev_wifi'"
  nmcli connection up "$prev_wifi" > /dev/null 2>&1 \
    || echo "WARNING: could not reconnect to '$prev_wifi'" >&2
}
trap restore_wifi EXIT

# Join a Wi-Fi network via NetworkManager, with rescans: right after the
# unit reboots or renames its network, the first scan often misses it.
# A stale saved profile with the same name (from earlier attempts, possibly
# with a wrong password) shadows `device wifi connect` on some nmcli
# versions, so recreate it from scratch. The last error is kept in
# $join_err for the caller's failure message.
join_wifi() {
  s="$1"
  p="$2"
  join_err=""
  for _ in 1 2 3; do
    nmcli device wifi rescan > /dev/null 2>&1 || true
    nmcli connection delete "$s" > /dev/null 2>&1 || true
    if [ -n "$p" ]; then
      join_err="$(nmcli device wifi connect "$s" password "$p" 2>&1 > /dev/null)" && return 0
    else
      join_err="$(nmcli device wifi connect "$s" 2>&1 > /dev/null)" && return 0
    fi
    sleep 3
  done
  return 1
}

wait_host() {
  for _ in $(seq 15); do
    ping -c 1 -W 1 "$host" > /dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Apply the config over ssh; sets $confirmed (1 = clean SETUP-COMPLETE),
# hard-fails when the unit reports errors. Legacy key algorithms: RouterOS
# v6 sshd only offers ssh-rsa, which modern OpenSSH rejects by default;
# harmless on v7. Host keys differ per unit, so they are not pinned.
apply_config() {
  note "configuring $host (you'll be asked for the unit's admin password)"
  out="$(ssh \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    "admin@$host" "$remote_script")" || true
  confirmed=0
  if [ "$out" = "SETUP-COMPLETE" ]; then
    confirmed=1
  elif [ "${out%SETUP-COMPLETE}" != "$out" ]; then
    # RouterOS prints nothing on success, so output before the marker = errors.
    echo "$out" >&2
    fail "the unit reported the errors above"
  elif [ -n "$out" ]; then
    echo "$out" >&2
  fi
}

if join_wifi "$unit_ssid" "$unit_pw"; then
  note "joined the unit's Wi-Fi '$unit_ssid'"
elif join_wifi "$ssid" "$pw"; then
  note "'$unit_ssid' not found; joined '$ssid' instead (unit already configured?)"
else
  fail "could not join '$unit_ssid' or '$ssid' — is the unit powered, in range, and are the sticker credentials right? (nmcli: ${join_err:-no error output})"
fi
wait_host || fail "joined the Wi-Fi but $host does not answer pings"

apply_config
if [ "$confirmed" != 1 ]; then
  # Expected: the final command renamed the Wi-Fi out from under our session.
  note "session dropped while the Wi-Fi change applied; rejoining '$ssid' to verify"
  join_wifi "$ssid" "$pw" || fail "the new Wi-Fi '$ssid' never appeared — re-run this script"
  wait_host || fail "joined '$ssid' but $host does not answer pings"
  apply_config
  [ "$confirmed" = 1 ] || fail "could not confirm convergence — re-run this script"
fi

# The unit's default Wi-Fi is gone; drop the NetworkManager profile for it.
nmcli connection delete "$unit_ssid" > /dev/null 2>&1 || true
note "done: '$ssid' is up (WPA2), ether1 bridged into the LAN, DHCP served by the unit"
