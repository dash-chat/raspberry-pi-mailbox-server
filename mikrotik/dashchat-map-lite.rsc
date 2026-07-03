# Dash Chat mesh AP — MikroTik mAP lite provisioning (RouterOS, legacy
# `wireless` package; written for v7, v6.49+ compatible).
#
# Every unit broadcasts the same `dashchat` WPA2 network AND automatically
# forms WDS bridge links with any other unit in range (dynamic WDS requires
# the same SSID, security profile, and a fixed shared channel). Linked units
# merge into one L2 network, so the Raspberry Pis (joined to the SSID) see
# each other over mDNS and their mailboxes start replicating on their own.
# Phones running Dash Chat join the same SSID and auto-discover the mailboxes.
#
# Apply on a factory-fresh unit (or after a reset):
#   /system reset-configuration no-defaults=yes skip-backup=yes
# then upload this file (Files) and run:
#   /import dashchat-map-lite.rsc
#
# Addressing: each unit self-assigns 10.<B5>.<B6>.1/8 (B5/B6 = last two bytes
# of its wireless MAC, so units don't collide) and serves DHCP leases from
# 10.<B5>.<B6>.10-254 with a /8 mask and no gateway/DNS — a purely offline
# LAN, phones keep using mobile data for internet. Disjoint per-unit pools let
# several DHCP servers coexist on the merged mesh network.

:local mac [/interface wireless get wlan1 mac-address]
:local b5 [:tonum ("0x" . [:pick $mac 12 14])]
:local b6 [:tonum ("0x" . [:pick $mac 15 17])]
:local net ("10." . $b5 . "." . $b6)

/system identity set name=("dashchat-" . $b5 . "-" . $b6)

# One bridge for everything; RSTP breaks the loops a WDS full mesh creates
# when three or more units are in mutual range.
/interface bridge add name=bridge protocol-mode=rstp comment="dashchat mesh LAN"
/interface bridge port add bridge=bridge interface=ether1

/interface wireless security-profiles add name=dashchat mode=dynamic-keys \
    authentication-types=wpa2-psk wpa2-pre-shared-key=dashchat

# Fixed frequency: dynamic WDS links only form between APs on the same
# channel, so `frequency=auto` would break unit-to-unit meshing.
# multicast-helper=full converts multicast to per-client unicast, which makes
# mDNS reliable for phones in power-save.
/interface wireless set wlan1 mode=ap-bridge band=2ghz-b/g/n channel-width=20mhz \
    frequency=2437 ssid=dashchat security-profile=dashchat country=spain \
    installation=indoor wds-mode=dynamic wds-default-bridge=bridge \
    multicast-helper=full disabled=no
/interface bridge port add bridge=bridge interface=wlan1

/ip address add address=($net . ".1/8") interface=bridge
/ip pool add name=dashchat ranges=($net . ".10-" . $net . ".254")
/ip dhcp-server add name=dashchat interface=bridge address-pool=dashchat disabled=no
/ip dhcp-server network add address=10.0.0.0/8 comment="no gateway/DNS: offline mesh LAN"

# Same convenience default as the Pi image — change both before deploying
# anywhere you don't fully trust.
/user set admin password=dashchat
