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
    unzip
    python3
    nodejs
    nodePackages.pnpm
    jq
  ];

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
        OpenClaw will automatically connect to it via SEARXNG_URL.
        No API key required.
      '';
    };

    searxng.url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:8888";
      description = ''
        URL of the SearXNG instance for OpenClaw to use.
        Defaults to the local instance started by enableSearxng.
        Override if you run SearXNG on a different host or port.
      '';
    };

    clawhubSkills = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "ivangdavila/self-improving" "someone/some-skill" ];
      description = ''
        List of ClawHub skill slugs to install automatically.
        Each entry is "<author>/<skill-name>" as shown in the ClawHub URL.
        Skills are downloaded and extracted into the OpenClaw skills directory
        on service start if not already present.
        Browse skills at https://clawhub.ai
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
        SEARXNG_URL = lib.mkIf cfg.enableSearxng cfg.searxng.url;
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
      };

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


          ${concatMapStringsSep "\n" (model: ''
            if ! ollama list 2>/dev/null | grep -q "^${model}"; then
              echo "Pre-pulling model: ${model}" >&2
              ollama pull ${model} 2>&1 || true
            fi
          '') cfg.prePullModels}

          ${concatMapStringsSep "\n" (slug:
            let skillName = builtins.baseNameOf slug; in ''
            SKILL_DIR="${openclawStateDir}/skills/${skillName}"
            if [ ! -d "$SKILL_DIR" ]; then
              echo "Installing ClawHub skill: ${slug}..." >&2
              mkdir -p "$SKILL_DIR"
              TMP_ZIP=$(mktemp /tmp/skill-XXXXXX.zip)
              if curl -fsSL "https://wry-manatee-359.convex.site/api/v1/download?slug=${skillName}" \
                  -o "$TMP_ZIP" 2>&1; then
                unzip -q "$TMP_ZIP" -d "$SKILL_DIR" 2>&1 \
                  && echo "Skill ${slug} installed." >&2 \
                  || echo "Failed to extract skill ${slug}." >&2
              else
                echo "Failed to download skill ${slug}." >&2
                rm -rf "$SKILL_DIR"
              fi
              rm -f "$TMP_ZIP"
            fi
          '') cfg.clawhubSkills}

          if [ -f "${openclawStateDir}/openclaw.json" ]; then
            echo "OpenClaw configured. Starting gateway..." >&2
            openclaw gateway 2>&1

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
          secret_key = lib.mkDefault "change-me-to-a-random-string";
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
