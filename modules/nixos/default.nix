{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.aiAgent;

  ollamaPackage =
    if cfg.gpuAcceleration == "cuda" then
      pkgs.ollama-cuda or pkgs.ollama
    else if cfg.gpuAcceleration == "rocm" then
      pkgs.ollama-rocm or pkgs.ollama
    else if cfg.gpuAcceleration == "vulkan" then
      pkgs.ollama-vulkan or pkgs.ollama
    else pkgs.ollama;

  nixagBotHome = "/var/lib/nixag-bot";
  openclawStateDir = "${nixagBotHome}/.openclaw";
  npmGlobalPrefix = "${nixagBotHome}/.npm-global";

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
      chown -R nixag-bot:nixag-bot "${openclawStateDir}/skills"
    ''
  else
    null;

  nixagOcDebugScript = pkgs.writeShellScriptBin "nixag-oc-debug" ''
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
      sudo -u nixag-bot env HOME=${nixagBotHome} ollama ps 2>/dev/null \
        | sed 's/^/    /' || warn "Could not list loaded models"
      echo -e "\n  Available models:"
      sudo -u nixag-bot env HOME=${nixagBotHome} ollama list 2>/dev/null \
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
      fail "No config at ${openclawStateDir}/openclaw.json — run: nixag-oc configure"
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
    tail -n 10 /var/log/openclaw/openclaw.log 2>/dev/null | sed 's/^/  /' \
      || warn "No stdout log yet"
    echo -e "\n  --- stderr (last 10 lines) ---"
    tail -n 10 /var/log/openclaw/openclaw-error.log 2>/dev/null | sed 's/^/  /' \
      || warn "No stderr log yet"

    hdr "Resource Usage"
    echo -e "\n  Memory:"
    free -h | sed 's/^/    /'
    echo -e "\n  Disk (openclaw state):"
    du -sh ${nixagBotHome} 2>/dev/null | sed 's/^/    /' || true
    du -sh /var/log/openclaw 2>/dev/null | sed 's/^/    /' || true
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
    users.users.nixag-bot = {
      isSystemUser = true;
      group = "nixag-bot";
      home = nixagBotHome;
      createHome = true;
      description = "Service account for AI Agent (OpenClaw and Ollama)";
      shell = "${pkgs.bash}/bin/bash";
    };

    users.groups.nixag-bot = { };

    services.ollama = {
      enable = true;
      package = ollamaPackage;
    };

    systemd.services.openclaw = {
      description = "OpenClaw AI Assistant Gateway";
      after = [ "network.target" "ollama.service" ];
      wants = [ "ollama.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;

      path = with pkgs; [ bash coreutils gnugrep iproute2 ] ++ openclawTools ++ [ ollamaPackage ];

      environment = {
        NPM_CONFIG_PREFIX = npmGlobalPrefix;
        HOME = nixagBotHome;
        OPENCLAW_STATE_DIR = openclawStateDir;
        OPENCLAW_HOME = nixagBotHome;
        OPENCLAW_NIX_MODE = "1";
      };

      serviceConfig = {
        Type = "simple";
        User = "nixag-bot";
        Group = "nixag-bot";
        WorkingDirectory = nixagBotHome;
        StandardOutput = "append:/var/log/openclaw/openclaw.log";
        StandardError = "append:/var/log/openclaw/openclaw-error.log";
        Restart = "on-failure";
        RestartSec = "15s";
        PrivateTmp = false;
        ProtectSystem = false;
        ProtectHome = false;
        ReadWritePaths = [ nixagBotHome "/var/lib/ollama" "/var/log/openclaw" ];
      } // (optionalAttrs (deploySearxngSkillScript != null) {
        ExecStartPre = [ "+${deploySearxngSkillScript}" ];
      });

      script = let
        modelFlag = if cfg.defaultModel != null then "--model ${cfg.defaultModel}" else "";
      in ''
        export PATH="${npmGlobalPrefix}/bin:$PATH"

        export HOME="${nixagBotHome}"
        git config --global url."https://github.com/".insteadOf "ssh://git@github.com/" 2>/dev/null || true
        git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
        export GIT_CEILING_DIRECTORIES="${nixagBotHome}"

        while true; do

          until ollama list > /dev/null 2>&1; do
            echo "Waiting for Ollama to become ready..." >&2
            sleep 3
          done
          echo "Ollama is ready." >&2

          if ! command -v openclaw > /dev/null 2>&1; then
            echo "OpenClaw not found. Installing via npm into ${npmGlobalPrefix}..." >&2
            mkdir -p "${npmGlobalPrefix}"
            cd "${nixagBotHome}"
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

          # Build UI assets if not already built (runs every restart, fast no-op if up to date).
          OC_DIR="${npmGlobalPrefix}/lib/node_modules/openclaw"
          if [ -d "$OC_DIR" ] && [ ! -d "$OC_DIR/assets/app" ]; then
            echo "Building OpenClaw UI assets..." >&2
            cd "$OC_DIR"
            pnpm ui:build 2>&1 \
              && echo "UI assets built successfully." >&2 \
              || echo "UI build failed (non-fatal, continuing)..." >&2
            cd "${nixagBotHome}"
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
            echo "  sudo -u nixag-bot env PATH=${npmGlobalPrefix}/bin:\$PATH \\" >&2
            echo "    OLLAMA_HOST=http://localhost:11434 \\" >&2
            echo "    openclaw onboard ${modelFlag}" >&2
            echo "" >&2
            echo "Or use: nixag-oc-onboard" >&2
            echo "Then restart: sudo systemctl restart openclaw" >&2
            echo "========================================" >&2
            sleep 30
          fi

        done
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/log/openclaw          0755 nixag-bot nixag-bot -"
      "d ${openclawStateDir}        0755 nixag-bot nixag-bot -"
      "d ${npmGlobalPrefix}         0755 nixag-bot nixag-bot -"
      "d ${npmGlobalPrefix}/bin     0755 nixag-bot nixag-bot -"
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

    environment.systemPackages = openclawTools ++ [ nixagOcDebugScript ];

    # Ensure /etc/zshrc is generated so environment.shellAliases reach zsh users too.
    programs.zsh.enable = true;
    programs.bash.enableCompletion = true;

    # environment.shellAliases works for bash, zsh, and fish
    environment.shellAliases = {
      nixag-oc          = "sudo -u nixag-bot env HOME=${nixagBotHome} PATH=${npmGlobalPrefix}/bin:/run/current-system/sw/bin:$PATH OLLAMA_HOST=http://localhost:11434 OLLAMA_API_KEY=ollama-local openclaw";
      nixag-oc-onboard  = "sudo -u nixag-bot env HOME=${nixagBotHome} PATH=${npmGlobalPrefix}/bin:/run/current-system/sw/bin:$PATH OLLAMA_HOST=http://localhost:11434 OLLAMA_API_KEY=ollama-local openclaw onboard";
      nixag-oc-debug    = "sudo nixag-oc-debug";
      nixag-oc-logs     = "sudo tail -f /var/log/openclaw/openclaw.log";
      nixag-oc-errors   = "sudo tail -f /var/log/openclaw/openclaw-error.log";
      nixag-oc-journal  = "sudo journalctl -u ollama -u openclaw -f";
      nixag-oc-restart  = "sudo systemctl restart openclaw";
      nixag-oc-stop     = "sudo systemctl stop openclaw";
      nixag-oc-start    = "sudo systemctl start openclaw";
      nixag-oc-status   = "systemctl status ollama openclaw";
    };

    services.logrotate = {
      enable = true;
      settings = {
        "/var/log/openclaw/openclaw.log" = {
          frequency  = "daily";
          rotate     = 7;
          compress   = true;
          missingok  = true;
          notifempty = true;
          size       = "50M";
          copytruncate = true;
        };
        "/var/log/openclaw/openclaw-error.log" = {
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
