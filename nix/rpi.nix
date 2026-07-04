# Raspberry Pi 5 appliance-specific tweaks.
#
# The heavy lifting — vendor kernel (linux-rpi), matched firmware/DTBs, the
# firmware partition, U-Boot/generational bootloader, and config.txt generation
# — is all handled by the `nixos-raspberrypi` modules imported in flake.nix
# (raspberry-pi-5.base + sd-image). Only what's specific to this appliance lives
# here.
{ lib, pkgs, ... }:
{
  # The sd-image base profile enables ZFS; its out-of-tree module isn't used by
  # this appliance and can fail to build against the vendor kernel, so keep it
  # off.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # brcmfmac needs the Pi's CYW43455 NVRAM blobs to bring up wlan0, which this
  # appliance uses to host the mesh (mAP-less units) or join a network as a
  # client. Redistributable firmware alone doesn't include them. The
  # nixos-raspberrypi overlays make this the version matched to the kernel.
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  # Let the Pi 5 deliver full current to its USB-A ports so it can power
  # peripherals (e.g. a USB-powered MikroTik mAP lite). By default the Pi 5 caps
  # USB-A output at 600 mA unless it detects a 5 A PSU; this declares that the
  # supply can provide enough, unlocking up to ~1.6 A across USB-A. Emitted under
  # the [pi5] filter in config.txt.
  hardware.raspberry-pi.config.pi5.options.usb_max_current_enable = {
    enable = true;
    value = true;
  };
}
