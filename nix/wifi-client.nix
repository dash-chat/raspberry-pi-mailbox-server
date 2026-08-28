# Optional Wi-Fi *client* (station mode): join an existing network using
# credentials read at boot from the FAT boot partition, so they can be set at
# flash time (`just flash <device> <wifi-env-file>`) or edited later on the SD
# card / over SSH — no rebuild or reflash.
#
# /boot/firmware/wifi.env format (values taken literally; surrounding quotes
# are stripped if present):
#
#   WIFI_SSID=MyNetwork
#   WIFI_PASSWORD=at-least-8-chars     # WPA2-PSK, 8-63 chars
#   WIFI_COUNTRY=ES                    # optional regulatory domain
#
# No wifi.env → the service doesn't start and the radio stays untouched, so
# ethernet-only stations behave exactly as before. This is client mode only:
# hosting the AP stays on the mAP lite (see README), not the Pi's brcmfmac.
{ pkgs, ... }:
let
  envFile = "/boot/firmware/wifi.env";
  conf = "/run/wpa_supplicant-wlan0.conf";
in
{
  # In-kernel regulatory database, so a WIFI_COUNTRY domain can be honoured.
  hardware.wirelessRegulatoryDatabase = true;

  # The CYW43455 firmware was purged with the old AP setup and the
  # nixos-raspberrypi base doesn't ship it: without this, brcmfmac probes but
  # wlan0 never appears.
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  systemd.services.wifi-client = {
    description = "Wi-Fi client on wlan0 (credentials from ${envFile})";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = envFile;
    # /boot/firmware is mounted on demand; without this ordering the condition
    # above is evaluated before the FAT partition is there and the unit is
    # silently skipped at boot.
    unitConfig.RequiresMountsFor = "/boot/firmware";

    path = with pkgs; [
      coreutils
      gnused
      util-linux # rfkill
      wpa_supplicant # wpa_passphrase + the daemon
    ];

    # The env file is re-read on every (re)start, so fixing it in place and
    # restarting the unit (or rebooting) picks the new credentials up.
    serviceConfig = {
      Restart = "always";
      RestartSec = 10;
    };
    unitConfig.StartLimitIntervalSec = 0;

    script = ''
      get() { sed -n "s/^$1=//p" ${envFile} | tr -d '\r' | head -n1; }
      unquote() { v="$1"; v="''${v%\"}"; v="''${v#\"}"; printf '%s' "$v"; }
      ssid="$(unquote "$(get WIFI_SSID)")"
      pw="$(unquote "$(get WIFI_PASSWORD)")"
      country="$(unquote "$(get WIFI_COUNTRY)")"

      [ -n "$ssid" ] || { echo "wifi.env: WIFI_SSID is missing/empty" >&2; exit 1; }
      { [ "''${#pw}" -ge 8 ] && [ "''${#pw}" -le 63 ]; } \
        || { echo "wifi.env: WIFI_PASSWORD must be 8-63 chars (WPA2)" >&2; exit 1; }

      # The generated config lives in /run (never persists) and holds only the
      # derived PSK: wpa_passphrase's commented plaintext line is stripped.
      umask 077
      {
        echo "ctrl_interface=DIR=/run/wpa_supplicant GROUP=root"
        [ -z "$country" ] || echo "country=$country"
        printf '%s\n' "$pw" | wpa_passphrase "$ssid" \
          | sed -e '/^\s*#psk=/d' -e 's/^network={/network={\n\tscan_ssid=1/'
      } > ${conf}

      rfkill unblock wifi || true
      # The device unit isn't a dependency: just wait for the radio to appear,
      # and let Restart retry if it doesn't.
      for _ in $(seq 30); do
        [ -e /sys/class/net/wlan0 ] && break
        sleep 1
      done
      [ -e /sys/class/net/wlan0 ] || { echo "wlan0 never appeared" >&2; exit 1; }

      exec wpa_supplicant -i wlan0 -c ${conf}
    '';
  };

  # Same trust as the ethernet LAN: phones on this Wi-Fi must reach the
  # mailbox's mDNS + dynamic iroh QUIC ports to discover and sync.
  networking.firewall.trustedInterfaces = [ "wlan0" ];
}
