# Optional Wi-Fi *client* (station mode): join an existing network using
# credentials read at boot from the FAT boot partition, so they can be set at
# flash time (`just flash <device> <wifi-env-file>`) or edited later on the SD
# card / over SSH — no rebuild or reflash.
#
# /boot/firmware/wifi.env format (values taken literally; surrounding quotes
# are stripped if present):
#
#   WIFI_SSID=MyNetwork
#   WIFI_PASSWORD=at-least-8-chars     # WPA2-PSK, 8-63 chars; empty/absent
#                                      # means an open network (key_mgmt=NONE)
#   WIFI_COUNTRY=ES                    # optional regulatory domain
#
# No wifi.env → the service exits immediately and the radio stays untouched,
# so ethernet-only stations behave as before. This is client mode only:
# hosting the AP stays on the mAP lite (see README), not the Pi's brcmfmac.
{ pkgs, ... }:
let
  envFile = "/boot/firmware/wifi.env";
  conf = "/run/wpa_supplicant.conf";
in
{
  # In-kernel regulatory database, so a WIFI_COUNTRY domain can be honoured.
  hardware.wirelessRegulatoryDatabase = true;

  # The CYW43455 firmware was purged with the old AP setup and the
  # nixos-raspberrypi base doesn't ship it: without this, brcmfmac probes but
  # wlan0 never appears.
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  # No ConditionPathExists / RequiresMountsFor on purpose: /boot/firmware is
  # an automount with a 1-minute idle timeout, so a systemd-side condition is
  # evaluated by PID1, which never triggers automounts (unmet at every boot),
  # and a Requires-style mount dependency propagates the idle unmount as a
  # stop of this service. The script probes the file instead — a normal
  # process access triggers the automount reliably.
  systemd.services.wifi-client = {
    description = "Wi-Fi client (credentials from ${envFile})";
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      coreutils
      gnused
      util-linux # rfkill
      wpa_supplicant
    ];

    # on-failure, not always: a missing wifi.env exits 0 (ethernet-only
    # station, no restart loop), while crashes and a malformed wifi.env keep
    # retrying — the env file is re-read on every restart, so fixing it in
    # place self-heals.
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = 10;
    };
    unitConfig.StartLimitIntervalSec = 0;

    script = ''
      set -euo pipefail
      if [ ! -e ${envFile} ]; then
        echo "no ${envFile} — Wi-Fi client disabled"
        exit 0
      fi
      get() { sed -n "s/^$1=//p" ${envFile} | tr -d '\r' | head -n1; }
      unquote() { v="$1"; v="''${v%\"}"; v="''${v#\"}"; printf '%s' "$v"; }
      ssid="$(unquote "$(get WIFI_SSID)")"
      pw="$(unquote "$(get WIFI_PASSWORD)")"
      country="$(unquote "$(get WIFI_COUNTRY)")"

      [ -n "$ssid" ] || { echo "wifi.env: WIFI_SSID is missing/empty" >&2; exit 1; }
      # An empty/absent WIFI_PASSWORD means an open network; anything else is
      # WPA2-PSK and has to satisfy the passphrase length the standard imposes.
      if [ -n "$pw" ]; then
        { [ "''${#pw}" -ge 8 ] && [ "''${#pw}" -le 63 ]; } \
          || { echo "wifi.env: WIFI_PASSWORD must be 8-63 chars (WPA2), or empty for an open network" >&2; exit 1; }
      fi

      # Plaintext passphrase on purpose: wpa_passphrase 2.11 aborts when fed
      # via a pipe (tcgetattr on non-tty), and the conf is root-only in /run —
      # the same secrecy as wifi.env on the FAT partition it came from.
      umask 077
      {
        echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=root"
        [ -z "$country" ] || echo "country=$country"
        if [ -n "$pw" ]; then
          printf 'network={\n  scan_ssid=1\n  ssid="%s"\n  psk="%s"\n}\n' "$ssid" "$pw"
        else
          printf 'network={\n  scan_ssid=1\n  ssid="%s"\n  key_mgmt=NONE\n}\n' "$ssid"
        fi
      } > ${conf}

      rfkill unblock wifi || true
      # The vendor kernel/udev renames the Pi 5 radio wlan0 -> wld0 (same
      # scheme as end0 for ethernet), so don't hardcode a name: wait for
      # whichever interface owns a phy80211, and let Restart retry if none
      # appears.
      wlan=""
      for _ in $(seq 30); do
        for d in /sys/class/net/*; do
          [ -e "$d/phy80211" ] && { wlan="$(basename "$d")"; break; }
        done
        [ -n "$wlan" ] && break
        sleep 1
      done
      [ -n "$wlan" ] || { echo "no wireless interface appeared" >&2; exit 1; }

      exec wpa_supplicant -i "$wlan" -c ${conf}
    '';
  };

  # Same trust as the ethernet LAN: phones on this Wi-Fi must reach the
  # mailbox's mDNS + dynamic iroh QUIC ports to discover and sync. Both names
  # because the vendor udev renames wlan0 -> wld0.
  networking.firewall.trustedInterfaces = [
    "wlan0"
    "wld0"
  ];
}
