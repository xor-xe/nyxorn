{ config, lib, pkgs, unstablePkgs ? pkgs, ... }:

with lib;

let
  cfg = config.services.aiAgent;

  # Use unstablePkgs (passed from the nyxorn flake) so we always get the latest
  # Ollama release. Falls back to host pkgs if unstablePkgs is not provided.
  ollamaPkgs = unstablePkgs;

  ollamaPackage =
    if cfg.gpuAcceleration == "cuda" then
      ollamaPkgs.ollama-cuda or ollamaPkgs.ollama
    else if cfg.gpuAcceleration == "rocm" then
      ollamaPkgs.ollama-rocm or ollamaPkgs.ollama
    else if cfg.gpuAcceleration == "vulkan" then
      ollamaPkgs.ollama-vulkan or ollamaPkgs.ollama
    else ollamaPkgs.ollama;

  nyxornHome      = "/var/lib/nyxorn-agent";
  openclawStateDir = "${nyxornHome}/.openclaw";
  npmGlobalPrefix  = "${nyxornHome}/.npm-global";

  openclawTools = with pkgs; [
    git
    curl
    python3
    nodejs
    nodePackages.pnpm
    jq
  ];

  searxngSkillStorePath = if cfg.enableSearxng && cfg.searxngSkillPath != null then
    pkgs.runCommand "searxng-web-search-skill" {} ''
      mkdir -p $out
      cp -r ${cfg.searxngSkillPath}/* $out/
    ''
  else
    null;

  deploySearxngSkillScript = if searxngSkillStorePath != null then
    pkgs.writeShellScript "deploy-searxng-skill" ''
      mkdir -p "${openclawStateDir}/skills/searxng-web-search"
      cp -r ${searxngSkillStorePath}/* "${openclawStateDir}/skills/searxng-web-search/"
      chown -R nyxorn-agent:nyxorn-agent "${openclawStateDir}/skills"
    ''
  else
    null;

  nyxornDebugScript = pkgs.writeShellScriptBin "nyxorn-debug" ''
    RESET='\033[0m'
    BOLD='\033[1m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'

    ok()   { echo -e "  ''${GREEN}✔''${RESET} $*"; }
    fail() { echo -e "  ''${RED}✘''${RESET} $*"; }
    warn() { echo -e "  ''${YELLOW}⚠''${RESET} $*"; }
    hdr()  { echo -e "\n''${BOLD}''${BLUE}══ $* ''${RESET}"; }

    hdr "Service Status"
    for svc in ollama openclaw; do
      state=$(systemctl is-active "$svc" 2>/dev/null)
      if [ "$state" = "active" ]; then
        ok "$svc: $state"
      else
        fail "$svc: $state"
      fi
    done

    hdr "Port Check"
    for port in 11434 18789 18791; do
      if ss -tlnp 2>/dev/null | grep -q "$port"; then
        ok "port $port is open"
      else
        fail "port $port is NOT open"
      fi
    done

    hdr "Ollama"
    if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
      ok "Ollama API reachable"
      echo -e "\n  Loaded models:"
      sudo -u nyxorn-agent env HOME=${nyxornHome} ollama ps 2>/dev/null \
        | sed 's/^/    /' || warn "Could not list loaded models"
      echo -e "\n  Available models:"
      sudo -u nyxorn-agent env HOME=${nyxornHome} ollama list 2>/dev/null \
        | sed 's/^/    /' || warn "Could not list models"
    else
      fail "Ollama API not reachable at http://localhost:11434"
    fi

    hdr "OpenClaw"
    if [ -f "${openclawStateDir}/openclaw.json" ]; then
      ok "Config found: ${openclawStateDir}/openclaw.json"
      model=$(${pkgs.jq}/bin/jq -r '.model // "not set"' ${openclawStateDir}/openclaw.json 2>/dev/null)
      ok "Configured model: $model"
    else
      fail "No config at ${openclawStateDir}/openclaw.json — run: nyxorn-onboard"
    fi

    oc_bin="${npmGlobalPrefix}/bin/openclaw"
    if [ -x "$oc_bin" ]; then
      oc_ver=$("$oc_bin" --version 2>/dev/null || echo "unknown")
      ok "OpenClaw binary: $oc_bin (v$oc_ver)"
    else
      fail "OpenClaw binary not found at $oc_bin"
    fi

    hdr "Recent Logs (openclaw)"
    echo -e "\n  --- stdout (last 10 lines) ---"
    tail -n 10 /var/log/nyxorn/openclaw.log 2>/dev/null | sed 's/^/  /' \
      || warn "No stdout log yet"
    echo -e "\n  --- stderr (last 10 lines) ---"
    tail -n 10 /var/log/nyxorn/openclaw-error.log 2>/dev/null | sed 's/^/  /' \
      || warn "No stderr log yet"

    hdr "Resource Usage"
    echo -e "\n  Memory:"
    free -h | sed 's/^/    /'
    echo -e "\n  Disk (nyxorn state):"
    du -sh ${nyxornHome} 2>/dev/null | sed 's/^/    /' || true
    du -sh /var/log/nyxorn 2>/dev/null | sed 's/^/    /' || true
    echo -e "\n  GPU (if AMD):"
    if command -v radeontop > /dev/null 2>&1; then
      timeout 2 radeontop -d - -l 1 2>/dev/null | tail -1 | sed 's/^/    /' \
        || warn "radeontop not reporting (GPU may be idle)"
    else
      warn "radeontop not installed — install rocmPackages.radeontop for GPU stats"
    fi

    echo ""
  '';

in
{
  options.services.aiAgent = {
    enable = mkEnableOption "AI Agent with OpenClaw and Ollama";

    defaultModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Default model for OpenClaw (optional, user selects during onboarding)";
      example = "glm-4.7-flash";
    };

    prePullModels = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "List of models to pre-pull on service start";
      example = [ "glm-4.7-flash" "gpt-oss-20b" ];
    };

    gpuAcceleration = mkOption {
      type = types.enum [ "auto" "rocm" "cuda" "vulkan" "cpu" ];
      default = "auto";
      description = ''
        GPU acceleration type:
        - auto: Try to auto-detect (falls back to CPU if detection fails)
        - rocm: AMD GPUs (ROCm)
        - cuda: NVIDIA GPUs (CUDA)
        - vulkan: Intel Arc GPUs or Vulkan-capable
        - cpu: CPU-only fallback
      '';
    };

    ollama.package = mkOption {
      type = types.package;
      default = ollamaPackage;
      defaultText = "pkgs.ollama (or rocm/cuda variant based on gpuAcceleration)";
      description = ''
        Ollama package to use. Override with a newer version from nixpkgs-unstable if
        your models require a newer Ollama release:
          services.aiAgent.ollama.package = pkgsUnstable.ollama;
      '';
    };

    enableSearxng = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable a local SearXNG instance for free, unlimited web search.
        Once enabled, OpenClaw can use http://localhost:8888 as its search endpoint.
        No API key required.
      '';
    };

    searxngSkillPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "./.cursor/skills/searxng-web-search";
      description = ''
        Path to the searxng-web-search skill directory.
        When set and enableSearxng is true, it is deployed into the service user's OpenClaw skills directory.
        If this repo is a flake input (e.g. `dotfiles`), set:
        `searxngSkillPath = dotfiles + "/.cursor/skills/searxng-web-search";`
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.nyxorn-agent = {
      isSystemUser = true;
      group = "nyxorn-agent";
      home = nyxornHome;
      createHome = true;
      description = "Service account for Nyxorn AI Agent (OpenClaw and Ollama)";
      shell = "${pkgs.bash}/bin/bash";
    };

    users.groups.nyxorn-agent = { };

    services.ollama = {
      enable = true;
      package = cfg.ollama.package;
      acceleration = lib.mkIf (cfg.gpuAcceleration != "auto" && cfg.gpuAcceleration != "cpu")
        cfg.gpuAcceleration;
    };

    systemd.services.openclaw = {
      description = "Nyxorn — OpenClaw AI Assistant Gateway";
      after = [ "network.target" "ollama.service" ];
      wants = [ "ollama.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;

      path = with pkgs; [ bash coreutils gnugrep iproute2 ] ++ openclawTools ++ [ cfg.ollama.package ];

      environment = {
        NPM_CONFIG_PREFIX = npmGlobalPrefix;
        HOME = nyxornHome;
        OPENCLAW_STATE_DIR = openclawStateDir;
        OPENCLAW_HOME = nyxornHome;
        OPENCLAW_NIX_MODE = "1";
      };

      serviceConfig = {
        Type = "simple";
        User = "nyxorn-agent";
        Group = "nyxorn-agent";
        WorkingDirectory = nyxornHome;
        StandardOutput = "append:/var/log/nyxorn/openclaw.log";
        StandardError = "append:/var/log/nyxorn/openclaw-error.log";
        Restart = "on-failure";
        RestartSec = "15s";
        PrivateTmp = false;
        ProtectSystem = false;
        ProtectHome = false;
        ReadWritePaths = [ nyxornHome "/var/lib/ollama" "/var/log/nyxorn" ];
      } // (optionalAttrs (deploySearxngSkillScript != null) {
        ExecStartPre = [ "+${deploySearxngSkillScript}" ];
      });

      script = let
        modelFlag = if cfg.defaultModel != null then "--model ${cfg.defaultModel}" else "";
      in ''
        export PATH="${npmGlobalPrefix}/bin:$PATH"

        export HOME="${nyxornHome}"
        git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" 2>/dev/null || true
        git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
        export GIT_CEILING_DIRECTORIES="${nyxornHome}"

        while true; do

          until ollama list > /dev/null 2>&1; do
            echo "Waiting for Ollama to become ready..." >&2
            sleep 3
          done
          echo "Ollama is ready." >&2

          if ! command -v openclaw > /dev/null 2>&1; then
            echo "OpenClaw not found. Installing via npm into ${npmGlobalPrefix}..." >&2
            mkdir -p "${npmGlobalPrefix}"
            cd "${nyxornHome}"
            npm install -g openclaw 2>&1 \
              && echo "OpenClaw installed successfully." >&2 \
              || {
                echo "npm install failed. Will retry in 60 seconds..." >&2
                sleep 60
                continue
              }
          else
            echo "OpenClaw found at: $(command -v openclaw)" >&2
          fi

          # Build UI assets if not already built.
          OC_DIR="${npmGlobalPrefix}/lib/node_modules/openclaw"
          if [ -d "$OC_DIR" ] && [ ! -d "$OC_DIR/assets/app" ]; then
            echo "Building OpenClaw UI assets..." >&2
            cd "$OC_DIR"
            pnpm ui:build 2>&1 \
              && echo "UI assets built successfully." >&2 \
              || echo "UI build failed (non-fatal, continuing)..." >&2
            cd "${nyxornHome}"
          fi

          ${concatMapStringsSep "\n" (model: ''
            if ! ollama list 2>/dev/null | grep -q "^${model}"; then
              echo "Pre-pulling model: ${model}" >&2
              ollama pull ${model} 2>&1 || true
            fi
          '') cfg.prePullModels}

          if [ -f "${openclawStateDir}/openclaw.json" ]; then
            echo "OpenClaw configured. Starting gateway..." >&2
            openclaw gateway 2>&1 || true

            echo "Waiting for gateway to bind to port 18789..." >&2
            for i in $(seq 1 15); do
              if ss -tlnp 2>/dev/null | grep -q 18789; then
                echo "OpenClaw gateway is up on port 18789." >&2
                break
              fi
              sleep 1
            done

            while ss -tlnp 2>/dev/null | grep -q 18789; do
              sleep 10
            done
            echo "OpenClaw gateway stopped. Restarting in 10 seconds..." >&2
            sleep 10
          else
            echo "========================================" >&2
            echo "OpenClaw requires first-time interactive setup." >&2
            echo "Run this in a terminal to complete setup:" >&2
            echo "" >&2
            echo "  nyxorn-onboard" >&2
            echo "" >&2
            echo "Then restart: nyxorn-restart" >&2
            echo "========================================" >&2
            sleep 30
          fi

        done
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/log/nyxorn             0755 nyxorn-agent nyxorn-agent -"
      "d ${openclawStateDir}         0755 nyxorn-agent nyxorn-agent -"
      "d ${npmGlobalPrefix}          0755 nyxorn-agent nyxorn-agent -"
      "d ${npmGlobalPrefix}/bin      0755 nyxorn-agent nyxorn-agent -"
    ];

    services.searx = mkIf cfg.enableSearxng {
      enable = true;
      settings = {
        server = {
          port = 8888;
          bind_address = "127.0.0.1";
          secret_key = "change-me-to-a-random-string";
        };
        search = {
          safe_search = 0;
          default_lang = "en";
        };
        engines = [
          { name = "google";     engine = "google";     shortcut = "g"; }
          { name = "duckduckgo"; engine = "duckduckgo"; shortcut = "d"; }
          { name = "bing";       engine = "bing";       shortcut = "b"; }
          { name = "bing_news";  engine = "bing_news";  shortcut = "bn"; }
          { name = "wikipedia";  engine = "wikipedia";  shortcut = "w"; }
          { name = "github";     engine = "github";     shortcut = "gh"; }
        ];
      };
    };

    environment.systemPackages = openclawTools ++ [ nyxornDebugScript ];

    programs.zsh.enable = true;
    programs.bash.completion.enable = true;

    environment.shellAliases = {
      nyxorn          = "sudo -u nyxorn-agent env HOME=${nyxornHome} PATH=${npmGlobalPrefix}/bin:/run/current-system/sw/bin:$PATH OLLAMA_HOST=http://localhost:11434 OLLAMA_API_KEY=ollama-local openclaw";
      nyxorn-onboard  = "sudo -u nyxorn-agent env HOME=${nyxornHome} PATH=${npmGlobalPrefix}/bin:/run/current-system/sw/bin:$PATH OLLAMA_HOST=http://localhost:11434 OLLAMA_API_KEY=ollama-local openclaw onboard";
      nyxorn-debug    = "sudo nyxorn-debug";
      nyxorn-logs     = "sudo tail -f /var/log/nyxorn/openclaw.log";
      nyxorn-errors   = "sudo tail -f /var/log/nyxorn/openclaw-error.log";
      nyxorn-journal  = "sudo journalctl -u ollama -u openclaw -f";
      nyxorn-restart  = "sudo systemctl restart openclaw";
      nyxorn-stop     = "sudo systemctl stop openclaw";
      nyxorn-start    = "sudo systemctl start openclaw";
      nyxorn-status   = "systemctl status ollama openclaw";
    };

    services.logrotate = {
      enable = true;
      settings = {
        "/var/log/nyxorn/openclaw.log" = {
          frequency  = "daily";
          rotate     = 7;
          compress   = true;
          missingok  = true;
          notifempty = true;
          size       = "50M";
          copytruncate = true;
        };
        "/var/log/nyxorn/openclaw-error.log" = {
          frequency  = "daily";
          rotate     = 7;
          compress   = true;
          missingok  = true;
          notifempty = true;
          size       = "50M";
          copytruncate = true;
        };
      };
    };
  };
}
