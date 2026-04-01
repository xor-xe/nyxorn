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
        # Reference the pre-built package from nix-openclaw's own evaluation
        # context (which uses its own nixpkgs with fetchPnpmDeps available).
        # Do NOT use nixpkgs.overlays — that would re-evaluate the package
        # through the host's nixpkgs (25.05) which lacks fetchPnpmDeps.
        services.openclaw-gateway.package = lib.mkDefault
          nix-openclaw.packages.${pkgs.system}.openclaw-gateway;
      };

      nixosModules.nyxorn = self.nixosModules.default;

      # ── packages (re-export for convenience) ─────────────────────────────────
      packages = forEachSystem (system: _pkgs: {
        openclaw         = nix-openclaw.packages.${system}.openclaw;
        openclaw-gateway = nix-openclaw.packages.${system}.openclaw-gateway;
        default          = nix-openclaw.packages.${system}.openclaw-gateway;
      });
    };
}
