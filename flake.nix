{
  description = "Nyxorn — AI agent layer for NixOS (OpenClaw or Hermes + Ollama, isolated service user)";

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

    # Upstream Hermes Agent (NousResearch) — NixOS module is imported only when
    # services.aiAgent.engine = "hermes". Follows our nixpkgs to avoid a second
    # nixpkgs evaluation for OpenClaw users.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-master, hermes-agent }:
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
        imports = [
          ./modules/nixos
          # Upstream Hermes Agent module — only adds options unless
          # services.hermes-agent.enable = true (set by our wrapper when
          # services.aiAgent.engine = "hermes"), so OpenClaw users pay no
          # closure cost.
          hermes-agent.nixosModules.default
        ];
        # Make pkgs.hermes-agent available for the Hermes engine branch.
        nixpkgs.overlays = [ hermes-agent.overlays.default ];
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
