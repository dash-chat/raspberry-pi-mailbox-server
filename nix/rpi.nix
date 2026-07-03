# Raspberry Pi 5 hardware specifics: kernel choice, Wi-Fi firmware, and the
# boot files the stock sd-image-aarch64.nix doesn't provide for the Pi 5.
{ lib, pkgs, ... }:
{
  # Mainline kernel instead of nixos-hardware's Pi 5 default (the Raspberry Pi
  # vendor kernel, which is compiled from source — many hours under aarch64
  # binfmt emulation on the x86_64 builder). Mainline is Hydra-cached and
  # covers everything this headless appliance needs on the Pi 5: RP1
  # (Ethernet/USB), SD card, PCIe and the CYW43455 Wi-Fi.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # The sd-image base profile enables ZFS, whose out-of-tree module doesn't
  # build against the latest mainline kernel (and the appliance doesn't use it).
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # nixos-hardware ships the Broadcom Wi-Fi/BT firmware in its Pi 4 module but
  # not in its Pi 5 module. Without the NVRAM blobs brcmfmac never brings up
  # wlan0 — and this appliance joins the mesh over Wi-Fi.
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];

  # The stock sd-image-aarch64.nix only knows Pi 3/4: its config.txt has no
  # [pi5] stanza and it ships no bcm2712 device tree or Pi 5-capable U-Boot.
  # The Pi 5's EEPROM bootloader reads config.txt itself (bootcode.bin and
  # start*.elf are ignored), loads the matching bcm2712 DTB from the firmware
  # partition, and chain-loads whatever kernel= names. We point it at a
  # Pi 5-capable U-Boot (rpi_arm64) so extlinux generation switching keeps
  # working exactly as on the other boards.
  sdImage.populateFirmwareCommands = lib.mkAfter ''
    cp ${pkgs.ubootRaspberryPiAarch64}/u-boot.bin firmware/u-boot-rpi-arm64.bin
    # Both C1/D0 SoC steppings; the firmware picks the one matching the board.
    cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-5-b.dtb firmware/
    cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712d0-rpi-5-b.dtb firmware/

    cat >> firmware/config.txt <<'EOF'

    [pi5]
    kernel=u-boot-rpi-arm64.bin

    # Let the Pi 5 deliver full current to its USB-A ports so it can power
    # peripherals (e.g. a USB-powered MikroTik mAP lite). By default the Pi 5
    # caps USB-A output at 600 mA unless it detects a 5 A PSU; this declares
    # that the supply can provide enough, unlocking up to ~1.6 A across USB-A.
    usb_max_current_enable=1
    EOF
  '';
}
