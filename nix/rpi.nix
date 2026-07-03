# Raspberry Pi 5 hardware specifics: kernel choice, Wi-Fi firmware, and the
# boot files the stock sd-image-aarch64.nix doesn't provide for the Pi 5.
{ lib, pkgs, ... }:
{
  # Use nixos-hardware's Pi 5 default kernel — the Raspberry Pi vendor kernel
  # (linux-rpi) — rather than overriding it to mainline. Mainline is Hydra-cached
  # and avoids a from-source kernel build, which is why it was chosen originally,
  # but on this hardware it hung at boot (frozen at the U-Boot logo, i.e. the
  # kernel never came up). The vendor tree is the best-supported Pi 5 boot path
  # (RP1 Ethernet/USB, the SD/MMC controller, PCIe and the CYW43455 Wi-Fi are all
  # covered), so we take it despite the cost: it compiles from source and isn't in
  # the nixpkgs cache — build the image on an aarch64 machine/CI, not under x86_64
  # binfmt emulation.

  # The sd-image base profile enables ZFS; its out-of-tree module isn't used by
  # this appliance and can fail to build against the kernel, so keep it off.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # nixos-hardware ships the Broadcom Wi-Fi/BT firmware in its Pi 4 module but
  # not in its Pi 5 module. Without the NVRAM blobs brcmfmac never brings up
  # wlan0 — which this appliance uses to host the mesh (mAP-less units) or to
  # join a network as a client.
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

    # The stock module cp's config.txt from the store, keeping it read-only.
    chmod +w firmware/config.txt
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
