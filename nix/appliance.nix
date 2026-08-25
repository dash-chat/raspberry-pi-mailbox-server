# Appliance basics: hostname and headless SSH administration.
#
# Networking is plain ethernet DHCP. The Wi-Fi AP that phones join is hosted
# by a MikroTik mAP lite (USB-powered from the Pi, cabled to it), not by the
# Pi itself — the Pi's own radio is unused.
#
# Deliberately minimal: anything re-added here must first prove necessary in
# the real-hardware e2e tests.
{ lib, ... }:
{
  networking.hostName = lib.mkDefault "dashchat-mailbox";

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkDefault true; # set false once you add a key
  };

  # SSH is already reachable over the trusted LAN interfaces, but open 22
  # explicitly so `ssh admin@<pi>` works regardless of which interface the
  # appliance ends up administered over.
  networking.firewall.allowedTCPPorts = [ 22 ];

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # Baked-in admin key so we can SSH in to inspect the appliance. Add more
    # keys here (or via the boot partition) and disable PasswordAuthentication
    # above for a locked-down deployment.
    openssh.authorizedKeys.keys = lib.mkDefault [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO8DVpvRgQ90MyMyiuNdvyMNAio9n2o/+57MyhZS2A5A guillem.cordoba@gmail.com"
    ];
    initialPassword = lib.mkDefault "dashchat";
  };
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # Let admin push store paths over ssh regardless of signatures, so
  # `just deploy` (nix copy over the ethernet cable) can update the system
  # without reflashing. Grants nothing new: admin already has passwordless
  # sudo.
  nix.settings.trusted-users = [ "admin" ];

  documentation.enable = lib.mkDefault false;
  system.stateVersion = lib.mkDefault "25.05";
}
