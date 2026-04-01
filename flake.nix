{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw + Ollama, isolated service user)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = fn: nixpkgs.lib.genAttrs supportedSystems
        (system: fn system nixpkgs.legacyPackages.${system});
    in
    {
      # ── NixOS module ─────────────────────────────────────────────────────────
      # Usage:
      #
      #   inputs.nyxorn.url = "github:youruser/nyxorn";
      #
      #   nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      #     modules = [
      #       nyxorn.nixosModules.default
      #       {
      #         services.aiAgent.enable = true;
      #         # services.aiAgent.gpuAcceleration = "rocm";
      #         # services.aiAgent.prePullModels = [ "llama3.2" ];
      #       }
      #     ];
      #   };
      nixosModules.default = import ./modules/nixos;
      nixosModules.nyxorn  = self.nixosModules.default;

      # ── checks / dev shell (optional) ────────────────────────────────────────
      devShells = forEachSystem (_system: pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.nixd pkgs.nil ];
        };
      });
    };
}
