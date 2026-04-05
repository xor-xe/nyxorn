{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw + Ollama, isolated service user)";

  inputs = {
    # nixpkgs-unstable is the default Ollama source — well-tested, typically 1-3 days
    # behind nixpkgs master. To tie Ollama to your system's nixpkgs instead, add:
    #   inputs.nyxorn.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Raw nixpkgs master source used when services.aiAgent.ollama.channel = "master".
    # Fetched as a plain source tree (flake = false) so it can be imported with
    # allowUnfree without needing a separate nixpkgs flake evaluation.
    nixpkgs-master = {
      url = "github:NixOS/nixpkgs/master";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-master }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      # nixpkgs-unstable — default Ollama source, well-tested.
      unstablePkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # nixpkgs master — bleeding edge, use when ollama.channel = "master".
      masterPkgsFor = system: import nixpkgs-master {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosModules.default = { pkgs, ... }: {
        imports = [ ./modules/nixos ];
        _module.args.unstablePkgs = unstablePkgsFor pkgs.system;
        _module.args.masterPkgs   = masterPkgsFor   pkgs.system;
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
