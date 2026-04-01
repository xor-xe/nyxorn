{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw + Ollama, isolated service user)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, nixpkgs-stable }:
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
      nixosModules.default = { pkgs, lib, ... }: {
        imports = [ ./modules/nixos ];
        # Always use the latest Ollama from nixos-unstable so new models work.
        # Users can still override: services.aiAgent.ollama.package = pkgs.ollama-rocm;
        services.aiAgent.ollama.package = lib.mkDefault
          nixpkgs.legacyPackages.${pkgs.system}.ollama;
      };
      nixosModules.nyxorn = self.nixosModules.default;

      # ── dev shell ─────────────────────────────────────────────────────────────
      devShells = forEachSystem (_system: pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.nixd pkgs.nil ];
        };
      });
    };
}
