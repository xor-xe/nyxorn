{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw + Ollama, isolated service user)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      # Unstable pkgs per system with allowUnfree for ollama-cuda/rocm.
      unstablePkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosModules.default = { pkgs, ... }: {
        imports = [ ./modules/nixos ];
        # Provides latest Ollama variants (ollama-cuda, ollama-rocm, etc.)
        # based on the gpuAcceleration option. allowUnfree needed for CUDA EULA.
        _module.args.unstablePkgs = unstablePkgsFor pkgs.system;
      };

      # Alias so users can reference either name.
      nixosModules.nyxorn = self.nixosModules.default;

      devShells = forEachSystem (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [ nixd nil nixpkgs-fmt ];
        };
      });
    };
}
