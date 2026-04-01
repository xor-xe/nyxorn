{ config, lib, pkgs, ... }:

let
  cfg = config.services.nyxorn;
  agentHome = "/var/lib/nixorn-agent";
in
{
  # ── options ───────────────────────────────────────────────────────────────

  options.services.nyxorn = {

    enable = lib.mkEnableOption "Nyxorn — OpenClaw AI gateway running as an isolated nixorn-agent user";

    package = lib.mkPackageOption pkgs "openclaw" { };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${agentHome}/.openclaw";
      description = ''
        Directory where OpenClaw stores its configuration (openclaw.json)
        and runtime state. Must be writable by the nixorn-agent user.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" "bob" ];
      description = ''
        Host users to add to the nixorn-agent group, granting them
        access to interact with the agent via its socket/API.
      '';
    };

    ollama = {
      acceleration = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "rocm" "cuda" ]);
        default = null;
        example = "rocm";
        description = ''
          GPU acceleration backend for Ollama.
          - null   → CPU only (default, always works)
          - "rocm" → AMD GPUs
          - "cuda" → NVIDIA GPUs
        '';
      };
    };

    enableSearxng = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable a local SearXNG instance (http://127.0.0.1:8888) that
        OpenClaw can use for free, unlimited web search.
        Requires setting services.searx.settings.server.secret_key
        to a random string in your configuration.
      '';
    };

  };

  # ── config ────────────────────────────────────────────────────────────────

  config = lib.mkIf cfg.enable {

    # ── service user & group ─────────────────────────────────────────────────

    users.groups.nixorn-agent = { };

    users.users = lib.mkMerge (
      [
        {
          nixorn-agent = {
            isSystemUser = true;
            group = "nixorn-agent";
            home = agentHome;
            createHome = true;
            description = "Nyxorn AI agent service account";
            shell = "${pkgs.bash}/bin/bash";
          };
        }
      ]
      ++ map (u: { ${u}.extraGroups = [ "nixorn-agent" ]; }) cfg.users
    );

    # ── state directories ────────────────────────────────────────────────────

    systemd.tmpfiles.rules = [
      "d ${agentHome}           0750 nixorn-agent nixorn-agent -"
      "d ${cfg.stateDir}        0750 nixorn-agent nixorn-agent -"
      "d /var/log/nixorn-agent  0750 nixorn-agent nixorn-agent -"
    ];

    # ── ollama ───────────────────────────────────────────────────────────────

    services.ollama = {
      enable = true;
      acceleration = cfg.ollama.acceleration;
    };

    # ── openclaw gateway service ─────────────────────────────────────────────

    systemd.services.nixorn-agent = {
      description = "Nyxorn — OpenClaw AI gateway";
      after = [ "network.target" "ollama.service" ];
      wants = [ "ollama.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;

      path = with pkgs; [ bash coreutils curl iproute2 ];

      environment = {
        HOME            = agentHome;
        OPENCLAW_HOME   = agentHome;
        OPENCLAW_STATE_DIR = cfg.stateDir;
        OPENCLAW_NIX_MODE  = "1";
        OLLAMA_HOST        = "http://127.0.0.1:11434";
      };

      serviceConfig = {
        Type            = "simple";
        User            = "nixorn-agent";
        Group           = "nixorn-agent";
        WorkingDirectory = agentHome;
        StandardOutput  = "append:/var/log/nixorn-agent/openclaw.log";
        StandardError   = "append:/var/log/nixorn-agent/openclaw-error.log";
        Restart         = "on-failure";
        RestartSec      = "15s";
        ReadWritePaths  = [ agentHome "/var/lib/ollama" "/var/log/nixorn-agent" ];
      };

      script = ''
        # Wait for Ollama to become ready before starting the gateway.
        until curl -sf http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do
          echo "Waiting for Ollama to be ready..." >&2
          sleep 3
        done

        # Abort with instructions if openclaw has not been configured yet.
        if [ ! -f "${cfg.stateDir}/openclaw.json" ]; then
          echo "════════════════════════════════════════" >&2
          echo "OpenClaw is not configured yet." >&2
          echo "" >&2
          echo "Run once as root to configure:" >&2
          echo "  nyxorn-configure" >&2
          echo "" >&2
          echo "Then restart the service:" >&2
          echo "  sudo systemctl restart nixorn-agent" >&2
          echo "════════════════════════════════════════" >&2
          sleep 30
          exit 1
        fi

        exec ${cfg.package}/bin/openclaw gateway
      '';
    };

    # ── shell aliases (all shells via environment.shellAliases) ──────────────

    environment.shellAliases = {
      nyxorn-configure = "sudo -u nixorn-agent env HOME=${agentHome} OPENCLAW_STATE_DIR=${cfg.stateDir} ${cfg.package}/bin/openclaw configure";
      nyxorn-status    = "systemctl status nixorn-agent ollama";
      nyxorn-restart   = "sudo systemctl restart nixorn-agent";
      nyxorn-stop      = "sudo systemctl stop nixorn-agent";
      nyxorn-start     = "sudo systemctl start nixorn-agent";
      nyxorn-logs      = "sudo tail -f /var/log/nixorn-agent/openclaw.log";
      nyxorn-errors    = "sudo tail -f /var/log/nixorn-agent/openclaw-error.log";
      nyxorn-journal   = "sudo journalctl -u nixorn-agent -u ollama -f";
    };

    # ── log rotation ─────────────────────────────────────────────────────────

    services.logrotate = {
      enable = true;
      settings = {
        "/var/log/nixorn-agent/openclaw.log" = {
          frequency = "daily";
          rotate = 7;
          compress = true;
          missingok = true;
          notifempty = true;
          size = "50M";
          copytruncate = true;
        };
        "/var/log/nixorn-agent/openclaw-error.log" = {
          frequency = "daily";
          rotate = 7;
          compress = true;
          missingok = true;
          notifempty = true;
          size = "50M";
          copytruncate = true;
        };
      };
    };

    # ── optional SearXNG ─────────────────────────────────────────────────────

    services.searx = lib.mkIf cfg.enableSearxng {
      enable = true;
      settings = {
        server = {
          port          = 8888;
          bind_address  = "127.0.0.1";
          # Set this to a random string in your configuration:
          # services.searx.settings.server.secret_key = "your-random-key";
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
