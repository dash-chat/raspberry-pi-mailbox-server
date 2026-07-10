{
  description = "Raspberry Pi NixOS image: Dash Chat LAN mailbox (mDNS announce/discovery + replication)";

  nixConfig = {
    extra-substituters = [
      "https://dash-chat.cachix.org"
      # Prebuilt vendor kernel/firmware/packages, so CI doesn't compile the
      # Raspberry Pi kernel from source on every build.
      "https://nixos-raspberrypi.cachix.org"
    ];
    extra-trusted-public-keys = [
      "dash-chat.cachix.org-1:oAsoaEZ7e4UJlveRXF45MJ1P+Tf3OKFN5QkB8BuPaiM="
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  inputs = {
    # nixos-raspberrypi owns the Pi 5 boot path: vendor kernel (linux-rpi) with
    # matched firmware/DTBs, declarative config.txt, and the generational
    # bootloader. It pins its own nixpkgs, which the system is built against.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    dash-chat.url = "github:dash-chat/dash-chat/replicating-local-mailbox-server";

    # Reuse the nixpkgs nixos-raspberrypi already pins (no extra download); used
    # only for the devShell tooling.
    nixpkgs.follows = "nixos-raspberrypi/nixpkgs";
  };

  outputs =
    {
      self,
      nixos-raspberrypi,
      dash-chat,
      nixpkgs,
      ...
    }:
    let
      # The flashing and cable-debugging helpers (scripts/), packaged so
      # consumers of this flake (e.g. the LARP repo) can reuse them with
      # pinned dependencies. writeShellApplication also shellchecks them at
      # build time.
      mkScripts =
        pkgs:
        let
          runtimeInputs = with pkgs; [
            util-linux # lsblk, findmnt, mount
            coreutils
            gnused
            gawk
          ];
          # For the direct-ethernet helpers: neighbor/link inspection + ssh.
          etherInputs = with pkgs; [
            coreutils
            gawk
            gnugrep
            iproute2
            iputils # ping
            openssh
          ];
        in
        rec {
          # Prints the single removable/USB non-system disk, or fails.
          detect-sd-card = pkgs.writeShellApplication {
            name = "detect-sd-card";
            inherit runtimeInputs;
            text = builtins.readFile ./scripts/detect-sd-card.sh;
          };
          # Flash an image + optional env dir; auto-detects the card.
          flash-sd-image = pkgs.writeShellApplication {
            name = "flash-sd-image";
            runtimeInputs = runtimeInputs ++ [ detect-sd-card ];
            text = builtins.readFile ./scripts/flash-sd-image.sh;
          };
          # Discover a Pi on a direct ethernet cable; prints its address.
          find-pi = pkgs.writeShellApplication {
            name = "find-pi";
            runtimeInputs = etherInputs;
            text = builtins.readFile ./scripts/find-pi.sh;
          };
          # SSH into the Pi on the cable (args become the remote command).
          ethernet-ssh = pkgs.writeShellApplication {
            name = "ethernet-ssh";
            runtimeInputs = etherInputs ++ [ find-pi ];
            text = builtins.readFile ./scripts/ethernet-ssh.sh;
          };
          # Push this machine's time to the Pi on the cable (writes the RTC
          # when present).
          ethernet-set-time = pkgs.writeShellApplication {
            name = "ethernet-set-time";
            runtimeInputs = etherInputs ++ [ find-pi ];
            text = builtins.readFile ./scripts/ethernet-set-time.sh;
          };
        };
    in
    {
      # Dev tooling (e.g. `just` for the flashing recipes). Enter with
      # `nix develop`.
      devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
        packages = with nixpkgs.legacyPackages.x86_64-linux; [
          just # flashing recipes
          zstd # decompress the built .img.zst
        ];
      };

      packages.x86_64-linux = {
        default = dash-chat.packages.x86_64-linux.replicating-local-mailbox-server;
        # The flashable Raspberry Pi SD image. Built for aarch64; on an x86_64
        # builder this needs `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
      }
      // mkScripts nixpkgs.legacyPackages.x86_64-linux;

      packages.aarch64-linux = {
        default = dash-chat.packages.aarch64-linux.replicating-local-mailbox-server;
        # Same image, built natively on an aarch64 builder (e.g. CI's arm runner).
        sdImage = self.nixosConfigurations.mailbox-pi.config.system.build.sdImage;
      }
      // mkScripts nixpkgs.legacyPackages.aarch64-linux;

      # `nixos-raspberrypi.lib.nixosSystem` is a drop-in for
      # `nixpkgs.lib.nixosSystem`: it pins `nixpkgs.hostPlatform = aarch64-linux`,
      # injects the vendor kernel/firmware overlays, trusts the binary cache, and
      # passes `nixos-raspberrypi` to the modules via specialArgs.
      nixosConfigurations.mailbox-pi = nixos-raspberrypi.lib.nixosSystem {
        modules = [
          {
            imports = with nixos-raspberrypi.nixosModules; [
              # Pi 5 board support: vendor kernel + matched firmware/DTBs, and
              # the config.txt / generational bootloader plumbing.
              raspberry-pi-5.base
              # Fixes/optimisations for the default rpi5 kernel's 16k page size.
              raspberry-pi-5.page-size-16k
              # Builds `config.system.build.sdImage`; also disables nixpkgs'
              # all-hardware profile (whose stray initrd modules break the
              # vendor kernel) and selects the generational bootloader for RPi5.
              sd-image
            ];
          }
          ./nix/nixos-module.nix
          ./nix/appliance.nix
          ./nix/rpi.nix
          ({ ... }: {
            services.dashchat-mailbox.package =
              dash-chat.packages.aarch64-linux.replicating-local-mailbox-server;
          })
        ];
      };
    };
}
