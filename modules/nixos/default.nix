{ config, lib, pkgs, ... }:

# Nyxorn wraps the official nix-openclaw NixOS module (services.openclaw-gateway)
# and adds Ollama integration, SearXNG, shell aliases, and sensible defaults for
# an isolated nixorn-agent service user.
#
# The base service options live at services.openclaw-gateway.*
# See: github:openclaw/nix-openclaw  nix/modules/nixos/openclaw-gateway.nix

let
  cfg = config.services.nyxorn;
  gw  = config.services.openclaw-gateway;
in
{
  # ── options ───────────────────────────────────────────────────────────────

  options.services.nyxorn = {

    enable = lib.mkEnableOption
      "Nyxorn — OpenClaw AI gateway with Ollama, running as an isolated service user";

    users = lib.mkOption {
      type    = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" "bob" ];
      description = ''
        Host users to add to the openclaw group, granting access to the agent.
      '';
    };

    ollama = {
      acceleration = lib.mkOption {
        type    = lib.types.nullOr (lib.types.enum [ "rocm" "cuda" ]);
        default = null;
        example = "rocm";
        description = ''
          GPU acceleration backend for Ollama.
          null → CPU only  |  "rocm" → AMD  |  "cuda" → NVIDIA
        '';
      };
    };

    enableSearxng = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = ''
        Enable a local SearXNG instance on http://127.0.0.1:8888 that OpenClaw
        can use for free, unlimited web search. When enabled, also set:
          services.searx.settings.server.secret_key = "your-random-string";
      '';
    };

  };

  # ── config ────────────────────────────────────────────────────────────────

  config = lib.mkIf cfg.enable {

    # ── openclaw-gateway defaults ────────────────────────────────────────────
    # Users can override any of these in their own config.

    services.openclaw-gateway = {
      enable     = true;
      user       = lib.mkDefault "nixorn-agent";
      group      = lib.mkDefault "nixorn-agent";
      stateDir   = lib.mkDefault "/var/lib/nixorn-agent";
      createUser = lib.mkDefault true;
      environment.OLLAMA_HOST = lib.mkDefault "http://127.0.0.1:11434";
      # Required to opt-in to Ollama provider auto-discovery (any non-empty value works).
      environment.OLLAMA_API_KEY = lib.mkDefault "ollama-local";
    };

    # Make openclaw binary available system-wide.
    environment.systemPackages = [ gw.package ];

    # ── add host users to the openclaw group ─────────────────────────────────

    users.users = lib.mkMerge
      (map (u: { ${u}.extraGroups = [ gw.group ]; }) cfg.users);

    # ── ollama ───────────────────────────────────────────────────────────────

    services.ollama = {
      enable       = true;
      acceleration = cfg.ollama.acceleration;
    };

    # ── shell aliases ─────────────────────────────────────────────────────────

    environment.shellAliases = {
      nyxorn-configure = "sudo -u ${gw.user} env HOME=${gw.stateDir} ${gw.package}/bin/openclaw configure";
      nyxorn-status    = "systemctl status ${gw.unitName} ollama";
      nyxorn-restart   = "sudo systemctl restart ${gw.unitName}";
      nyxorn-stop      = "sudo systemctl stop ${gw.unitName}";
      nyxorn-start     = "sudo systemctl start ${gw.unitName}";
      nyxorn-logs      = "sudo tail -f ${gw.logPath}";
      nyxorn-journal   = "sudo journalctl -u ${gw.unitName} -u ollama -f";
    };

    # ── log rotation ──────────────────────────────────────────────────────────

    services.logrotate = {
      enable = true;
      settings."${gw.logPath}" = {
        frequency  = "daily";
        rotate     = 7;
        compress   = true;
        missingok  = true;
        notifempty = true;
        size       = "50M";
        copytruncate = true;
      };
    };

    # ── optional SearXNG ──────────────────────────────────────────────────────

    services.searx = lib.mkIf cfg.enableSearxng {
      enable = true;
      settings = {
        server = {
          port         = 8888;
          bind_address = "127.0.0.1";
          # Set in your config: services.searx.settings.server.secret_key
        };
        search = {
          safe_search  = 0;
          default_lang = "en";
        };
        engines = [
          { name = "google";     engine = "google";     shortcut = "g"; }
          { name = "duckduckgo"; engine = "duckduckgo"; shortcut = "d"; }
          { name = "bing";       engine = "bing";       shortcut = "b"; }
          { name = "wikipedia";  engine = "wikipedia";  shortcut = "w"; }
          { name = "github";     engine = "github";     shortcut = "gh"; }
        ];
      };
    };

  };
}
