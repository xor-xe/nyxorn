{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw + Ollama, isolated service user)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Official OpenClaw Nix packaging — handles the derivation, deps, and updates.
    # Do NOT follow our nixpkgs: nix-openclaw requires nixos-unstable for
    # fetchPnpmDeps, which is not available in nixos-25.05.
    nix-openclaw.url = "github:openclaw/nix-openclaw";
  };

  outputs = { self, nixpkgs, nix-openclaw }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = fn: nixpkgs.lib.genAttrs supportedSystems
        (system: fn system nixpkgs.legacyPackages.${system});
    in
    {
      # ── NixOS modules ────────────────────────────────────────────────────────
      # Usage:
      #
      #   inputs.nyxorn.url = "github:youruser/nyxorn";
      #
      #   nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      #     modules = [
      #       nyxorn.nixosModules.default
      #       {
      #         services.nyxorn.enable = true;
      #         # services.nyxorn.ollama.acceleration = "rocm";
      #       }
      #     ];
      #   };
      nixosModules.default = { pkgs, lib, ... }: {
        imports = [
          # Bring in the official openclaw-gateway NixOS module.
          nix-openclaw.nixosModules.openclaw-gateway
          # Our thin wrapper: Ollama, SearXNG, aliases, nyxorn-agent defaults.
          ./modules/nixos
        ];
        # Apply the official overlay so pkgs.openclaw-gateway is resolvable.
        nixpkgs.overlays = [ nix-openclaw.overlays.default ];
      };

      nixosModules.nyxorn = self.nixosModules.default;

      # ── packages (re-export for convenience) ─────────────────────────────────
      packages = forEachSystem (system: pkgs: {
        openclaw         = nix-openclaw.packages.${system}.openclaw;
        openclaw-gateway = nix-openclaw.packages.${system}.openclaw-gateway;
        default          = nix-openclaw.packages.${system}.openclaw-gateway;
      });
    };
}
