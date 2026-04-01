{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw + Ollama, isolated service user)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forEachSystem = fn:
        nixpkgs.lib.genAttrs supportedSystems
          (system: fn system nixpkgs.legacyPackages.${system});
    in
    {
      # ── packages ────────────────────────────────────────────────────────────
      packages = forEachSystem (system: pkgs: {
        openclaw = pkgs.callPackage ./pkgs/openclaw {
          nix-update-script = pkgs.nix-update-script or pkgs.writeShellScript "nix-update-stub" "echo 'nix-update not available'";
        };
        default = self.packages.${system}.openclaw;
      });

      # ── overlay ──────────────────────────────────────────────────────────────
      # Add to your flake's nixpkgs overlays if you want pkgs.openclaw
      # available system-wide without using the NixOS module.
      overlays.default = final: _prev: {
        openclaw = final.callPackage ./pkgs/openclaw {
          nix-update-script = final.nix-update-script or final.writeShellScript "nix-update-stub" "echo 'nix-update not available'";
        };
      };

      # ── NixOS modules ────────────────────────────────────────────────────────
      # Usage in your flake:
      #
      #   inputs.nyxorn.url = "github:youruser/nyxorn";
      #
      #   nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      #     modules = [
      #       nyxorn.nixosModules.default
      #       { services.nyxorn.enable = true; }
      #     ];
      #   };
      nixosModules.default = { pkgs, lib, ... }: {
        imports = [ ./modules/nixos ];
        # Inject the openclaw package into pkgs so the module can find it.
        nixpkgs.overlays = [ self.overlays.default ];
      };

      # Alias so users can write either nyxorn.nixosModules.default
      # or nyxorn.nixosModules.nyxorn — both work.
      nixosModules.nyxorn = self.nixosModules.default;

      # ── apps ────────────────────────────────────────────────────────────────
      # `nix run .#update` — bump openclaw to the latest npm release.
      apps = forEachSystem (system: pkgs: {
        update = {
          type = "app";
          program = toString (pkgs.writeShellScript "nyxorn-update" ''
            export PATH="${pkgs.lib.makeBinPath (with pkgs; [
              curl jq nodejs npm nix prefetch-npm-deps
            ])}:$PATH"
            exec ${./pkgs/openclaw/update.sh}
          '');
        };
      });
    };
}
