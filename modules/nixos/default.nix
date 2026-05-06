{ config, lib, pkgs, unstablePkgs ? pkgs, masterPkgs ? unstablePkgs, ... }:

with lib;

let
  cfg = config.services.aiAgent;

  # Convenience — the active engine. OpenClaw is the default for backwards
  # compatibility with pre-Hermes nyxorn deployments.
  isOpenclaw = cfg.engine == "openclaw";
  isHermes   = cfg.engine == "hermes";

  # Pick the nixpkgs snapshot based on the user's channel preference.
  # "unstable" → nixpkgs-unstable (default, well-tested, 1-3 days behind master)
  # "master"   → nixpkgs master   (bleeding edge, new Ollama releases land same day)
  # Falls back to host pkgs if neither is injected by the flake wrapper.
  ollamaPkgs =
    if cfg.ollama.channel == "master" then masterPkgs
    else unstablePkgs;

  ollamaPackage =
    if cfg.gpuAcceleration == "cuda" then
      ollamaPkgs.ollama-cuda or ollamaPkgs.ollama
    else if cfg.gpuAcceleration == "rocm" then
      ollamaPkgs.ollama-rocm or ollamaPkgs.ollama
    else if cfg.gpuAcceleration == "vulkan" then
      ollamaPkgs.ollama-vulkan or ollamaPkgs.ollama
    else ollamaPkgs.ollama-cpu or ollamaPkgs.ollama;

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

  agentService =
    if isHermes then "hermes-agent"
    else "openclaw";

  hermesStateDir = "${nyxornHome}/.hermes";

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

    hdr "Engine"
    ok "engine: ${cfg.engine}"

    hdr "Service Status"
    for svc in ${optionalString cfg.ollama.enable "ollama"} ${agentService}; do
      state=$(systemctl is-active "$svc" 2>/dev/null)
      if [ "$state" = "active" ]; then
        ok "$svc: $state"
      else
        fail "$svc: $state"
      fi
    done

    ${optionalString isOpenclaw ''
    hdr "Port Check"
    for port in ${optionalString cfg.ollama.enable "11434"} 18789 18791; do
      if ss -tlnp 2>/dev/null | grep -q "$port"; then
        ok "port $port is open"
      else
        fail "port $port is NOT open"
      fi
    done
    ''}

    ${optionalString (isHermes && cfg.ollama.enable) ''
    hdr "Port Check"
    if ss -tlnp 2>/dev/null | grep -q 11434; then
      ok "port 11434 is open"
    else
      fail "port 11434 is NOT open"
    fi
    ''}

    ${optionalString cfg.ollama.enable ''
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
    ''}

    ${optionalString isOpenclaw ''
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
    ''}

    ${optionalString isHermes ''
    hdr "Hermes"
    if [ -f "${hermesStateDir}/config.yaml" ]; then
      ok "Config found: ${hermesStateDir}/config.yaml"
    else
      fail "No config at ${hermesStateDir}/config.yaml — first activation may not have run yet"
    fi

    if [ -f "${hermesStateDir}/.managed" ]; then
      ok "Managed-mode marker present (CLI mutations blocked)"
    else
      warn "Managed-mode marker missing — service may not have started yet"
    fi

    if [ -f "${hermesStateDir}/.env" ]; then
      ok "Env file present at ${hermesStateDir}/.env"
    else
      warn "No .env at ${hermesStateDir}/.env — set hermes.environmentFiles for API keys"
    fi

    if command -v hermes > /dev/null 2>&1; then
      hr_ver=$(hermes --version 2>/dev/null || echo "unknown")
      ok "hermes CLI on PATH (v$hr_ver)"
    else
      warn "hermes CLI not on PATH — set hermes.addToSystemPackages = true"
    fi

    hdr "Recent Logs (hermes-agent, journald)"
    journalctl -u hermes-agent -n 20 --no-pager 2>/dev/null | sed 's/^/  /' \
      || warn "Could not read journal"
    ''}

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

  # Helper script printed when users run nyxorn-onboard with engine = "hermes".
  hermesOnboardStub = pkgs.writeShellScriptBin "nyxorn-onboard-hermes" ''
    cat <<'EOF'
    Hermes runs in NixOS managed mode — interactive CLI setup is intentionally blocked.

    To configure the agent, edit your NixOS configuration:

      services.aiAgent.hermes.settings = {
        model.default = "anthropic/claude-sonnet-4";
      };
      services.aiAgent.hermes.environmentFiles = [
        # Path to a 0600 file containing OPENROUTER_API_KEY=... etc.
        # Use sops-nix or agenix in production.
        config.sops.secrets."hermes-env".path
      ];

    Then: sudo nixos-rebuild switch && sudo systemctl restart hermes-agent

    See `services.aiAgent.hermes.*` options or upstream docs:
      https://hermes-agent.nousresearch.com/docs/getting-started/nix-setup
    EOF
  '';

in
{
  options.services.aiAgent = {
    enable = mkEnableOption "AI Agent (OpenClaw or Hermes) with optional Ollama";

    engine = mkOption {
      type = types.enum [ "openclaw" "hermes" ];
      default = "openclaw";
      description = ''
        Which agent engine to run. Engines are mutually exclusive — only one
        runs at a time on a given host. Ollama and SearXNG remain shared
        infrastructure regardless of the engine.

        - "openclaw" (default): the original nyxorn engine. OpenClaw is
          installed via npm into the nyxorn-agent state dir on first start
          and runs as a long-lived gateway on port 18789. ClawHub skills
          (services.aiAgent.clawhubSkills) are supported.

        - "hermes": NousResearch's Hermes Agent, integrated through the
          upstream services.hermes-agent NixOS module. Configuration is
          declarative (services.aiAgent.hermes.settings) and the interactive
          `hermes setup` / `hermes config edit` CLI commands are blocked
          (managed mode). Plugins go through hermes.extraPlugins /
          hermes.extraPythonPackages instead of clawhubSkills.
      '';
    };

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
      type = types.enum [ "cpu" "rocm" "cuda" "vulkan" ];
      default = "cpu";
      description = ''
        GPU acceleration type:
        - cpu: CPU only (default)
        - cuda: NVIDIA GPUs
        - rocm: AMD GPUs
        - vulkan: Intel Arc / other Vulkan-capable GPUs
      '';
    };

    ollama.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to run a local Ollama instance.

        Set to false if you want OpenClaw only — for example when you plan to use
        a remote Ollama server, a cloud LLM provider, or configure the backend
        manually via nyxorn-onboard.

        When false: the Ollama service is not started, no GPU acceleration is
        configured, and prePullModels has no effect.
      '';
    };

    ollama.channel = mkOption {
      type = types.enum [ "unstable" "master" ];
      default = "unstable";
      description = ''
        Which nixpkgs snapshot to pull Ollama from.

        - "unstable" (default): nixpkgs-unstable — well-tested builds, typically
          1-3 days behind nixpkgs master. Suitable for most users.

        - "master": nixpkgs master — bleeding edge. New Ollama versions land here
          the same day they are packaged, before the unstable channel catches up.
          Use this when a newly released model (e.g. gemma4) requires a very
          recent Ollama that has not yet propagated to nixpkgs-unstable.

        Note: switching to "master" causes Nix to fetch a separate copy of nixpkgs
        master on the next rebuild. Run `nix flake update` in your dotfiles repo
        to ensure nyxorn's master snapshot is also up to date.
      '';
    };

    ollama.package = mkOption {
      type = types.package;
      default = ollamaPackage;
      defaultText = "ollama / ollama-cuda / ollama-rocm depending on gpuAcceleration and ollama.channel";
      description = ''
        Ollama package to use. Normally derived automatically from gpuAcceleration
        and ollama.channel. Override only if you need a custom build.
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

    searxng.secretKey = mkOption {
      type = types.str;
      default = "";
      description = ''
        Secret key for the local SearXNG instance. Required when enableSearxng = true.
        Generate one with: openssl rand -hex 32
      '';
    };

    clawhubSkills = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "ivangdavila/self-improving" "someone/some-skill" ];
      description = ''
        List of ClawHub skill slugs to install automatically (OpenClaw only).
        Each entry is "<author>/<skill-name>" as shown in the ClawHub URL.
        Skills are downloaded and extracted into the OpenClaw skills directory
        on service start if not already present.
        Browse skills at https://clawhub.ai

        Has no effect when services.aiAgent.engine = "hermes" — for Hermes,
        use services.aiAgent.hermes.extraPlugins /
        services.aiAgent.hermes.extraPythonPackages instead.
      '';
    };

    # Hermes engine — thin passthrough façade onto upstream services.hermes-agent.
    # All options here apply only when services.aiAgent.engine = "hermes".
    hermes = {
      settings = mkOption {
        type = types.attrs;
        default = { };
        description = ''
          Declarative Hermes config rendered as $HERMES_HOME/config.yaml.

          Supports arbitrary nesting; multiple definitions are deep-merged via
          lib.recursiveUpdate. Nyxorn auto-injects sensible defaults for
          model.base_url (when ollama.enable = true) and model.default (from
          services.aiAgent.defaultModel) — your settings always win.

          See: https://hermes-agent.nousresearch.com/docs/getting-started/nix-setup
        '';
        example = literalExpression ''
          {
            model.default = "anthropic/claude-sonnet-4";
            toolsets = [ "all" ];
            memory.memory_enabled = true;
          }
        '';
      };

      configFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Optional escape hatch: path to a hand-written config.yaml. When set,
          the `settings` option is ignored and the file is copied verbatim to
          $HERMES_HOME/config.yaml on every activation.
        '';
      };

      environmentFiles = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = ''
          Paths to env files containing Hermes secrets (provider API keys,
          messaging-platform tokens, etc.). Merged into $HERMES_HOME/.env at
          activation time.

          Use sops-nix or agenix in production — never put keys directly in
          Nix expressions, which end up in the world-readable /nix/store.
        '';
        example = literalExpression ''[ config.sops.secrets."hermes-env".path ]'';
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Non-secret environment variables for the Hermes service. Visible in
          /nix/store — do not put secrets here, use environmentFiles instead.
        '';
      };

      mcpServers = mkOption {
        type = types.attrsOf types.attrs;
        default = { };
        description = ''
          MCP (Model Context Protocol) server definitions. Each entry maps
          1:1 to upstream services.hermes-agent.mcpServers.<name>. Supports
          both stdio (command/args) and HTTP (url/headers) transports.
        '';
        example = literalExpression ''
          {
            filesystem = {
              command = "npx";
              args = [ "-y" "@modelcontextprotocol/server-filesystem" "/data/workspace" ];
            };
          }
        '';
      };

      documents = mkOption {
        type = types.attrsOf (types.either types.str types.path);
        default = { };
        description = ''
          Files installed into the agent's working directory on every
          activation. Keys are filenames, values are inline strings or paths.
          Hermes reads filenames like USER.md by convention.
        '';
      };

      extraPlugins = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          Directory plugin packages symlinked into $HERMES_HOME/plugins/ on
          activation. Each package must contain plugin.yaml + __init__.py.
        '';
      };

      skills = mkOption {
        type = types.attrsOf (types.either types.path types.package);
        default = { };
        description = ''
          Hermes skill bundles installed declaratively into
          $HERMES_HOME/skills/. Keys are paths under skills/ (typically
          "<category>/<skill-name>", matching the layout used by bundled
          skills); values are paths or packages whose root is the SKILL.md
          bundle (must contain a top-level SKILL.md).

          Stale entries are removed automatically on each rebuild. Conflicts
          with bundled skills of the same path will overwrite the bundled
          symlink — choose unique paths or override deliberately.
        '';
        example = literalExpression ''
          {
            "research/searxng-search" =
              (pkgs.fetchFromGitHub {
                owner = "user";
                repo  = "Sekurvia";
                rev   = "main";
                hash  = "sha256-...";
              }) + "/searxng-search";
          }
        '';
      };

      extraPythonPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          Python packages added to PYTHONPATH for entry-point plugin
          discovery. Build with python312Packages.buildPythonPackage.
        '';
      };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          Extra system packages made available to the agent (terminal
          commands, skills, cron jobs).
        '';
      };

      authFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to an OAuth credentials seed file (auth.json). Only copied
          on first deploy unless authFileForceOverwrite = true.
        '';
      };

      authFileForceOverwrite = mkOption {
        type = types.bool;
        default = false;
        description = "Always overwrite auth.json from authFile on activation.";
      };

      addToSystemPackages = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Add the `hermes` CLI to the system PATH and set HERMES_HOME
          system-wide so the interactive CLI shares state with the gateway
          service. Default true so the nyxorn-* aliases work out of the box.
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra args appended to `hermes gateway`.";
      };

      restart = mkOption {
        type = types.str;
        default = "always";
        description = "systemd Restart= policy for hermes-agent.";
      };

      restartSec = mkOption {
        type = types.int;
        default = 5;
        description = "systemd RestartSec= value for hermes-agent.";
      };

      container = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Run Hermes in a persistent OCI container instead of a native
            systemd service. Lets the agent `apt`/`pip`/`npm install`
            packages at runtime that survive restarts and rebuilds.

            Requires Docker (default) or Podman to be enabled on the host.
          '';
        };

        backend = mkOption {
          type = types.enum [ "docker" "podman" ];
          default = "docker";
          description = "Container runtime backend.";
        };

        image = mkOption {
          type = types.str;
          default = "ubuntu:24.04";
          description = "Base OCI image (pulled at runtime).";
        };

        extraVolumes = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra volume mounts in `host:container[:mode]` form.";
          example = [ "/home/user/projects:/projects:rw" ];
        };

        extraOptions = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Extra args passed to `docker create` / `podman create`.";
          example = [ "--gpus" "all" ];
        };

        hostUsers = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Interactive users who get a ~/.hermes symlink to the service
            stateDir and are auto-added to the nyxorn-agent group.
          '';
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.enableSearxng || cfg.searxng.secretKey != "";
        message = ''
          services.aiAgent.enableSearxng = true requires a secret key.
          Set: services.aiAgent.searxng.secretKey = "$(openssl rand -hex 32)";
        '';
      }
      {
        assertion = cfg.ollama.enable || cfg.prePullModels == [];
        message = ''
          services.aiAgent.prePullModels requires services.aiAgent.ollama.enable = true.
          Remove prePullModels or re-enable the local Ollama service.
        '';
      }
      {
        assertion = cfg.ollama.enable || cfg.gpuAcceleration == "cpu";
        message = ''
          services.aiAgent.gpuAcceleration requires services.aiAgent.ollama.enable = true.
          GPU acceleration has no effect without a local Ollama instance.
        '';
      }
      {
        assertion = isOpenclaw || cfg.clawhubSkills == [ ];
        message = ''
          services.aiAgent.clawhubSkills is OpenClaw-only and has no effect when
          services.aiAgent.engine = "hermes".

          For Hermes, install plugins via:
            services.aiAgent.hermes.extraPlugins        # directory plugins
            services.aiAgent.hermes.extraPythonPackages # entry-point plugins

          Either set services.aiAgent.engine = "openclaw" or remove clawhubSkills.
        '';
      }
      {
        assertion = !isHermes || cfg.ollama.enable || cfg.hermes.environmentFiles != [ ];
        message = ''
          services.aiAgent.engine = "hermes" without services.aiAgent.ollama.enable
          requires at least one entry in services.aiAgent.hermes.environmentFiles
          so Hermes has a remote LLM provider key (OPENROUTER_API_KEY, ANTHROPIC_API_KEY, ...).

          Either enable local Ollama, or set:
            services.aiAgent.hermes.environmentFiles = [ <path-to-secret-env-file> ];
        '';
      }
      {
        assertion = !(isHermes && cfg.hermes.container.enable && cfg.hermes.container.backend == "podman")
                    || config.virtualisation.podman.enable or false;
        message = ''
          services.aiAgent.hermes.container.enable = true with backend = "podman"
          requires virtualisation.podman.enable = true on the host.
        '';
      }
    ];
    users.users.nyxorn-agent = {
      isSystemUser = true;
      group = "nyxorn-agent";
      home = nyxornHome;
      createHome = true;
      description = "Service account for Nyxorn AI Agent (OpenClaw and Ollama)";
      shell = "${pkgs.bash}/bin/bash";
    };

    users.groups.nyxorn-agent = { };

    services.ollama = mkIf cfg.ollama.enable {
      enable = true;
      package = cfg.ollama.package;
      acceleration = lib.mkIf (cfg.gpuAcceleration != "cpu") cfg.gpuAcceleration;
    };

    # Engine-agnostic model pre-pull. Runs once after Ollama is up and pulls
    # any tags the user listed in services.aiAgent.prePullModels that aren't
    # already on disk. Without this, prePullModels would only fire from the
    # OpenClaw bootstrap loop, leaving Hermes users with HTTP 404s on first
    # chat when their default model hasn't been fetched yet.
    systemd.services.nyxorn-prepull = mkIf (cfg.ollama.enable && cfg.prePullModels != [ ]) {
      description = "Nyxorn — pre-pull Ollama models";
      after    = [ "ollama.service" "network-online.target" ];
      wants    = [ "ollama.service" "network-online.target" ];
      requires = [ "ollama.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [ cfg.ollama.package pkgs.coreutils pkgs.gnugrep ];

      serviceConfig = {
        Type = "oneshot";
        User = "nyxorn-agent";
        Group = "nyxorn-agent";
        RemainAfterExit = true;
        Environment = [
          "HOME=${nyxornHome}"
          "OLLAMA_HOST=http://127.0.0.1:11434"
        ];
      };

      script = ''
        until ollama list >/dev/null 2>&1; do
          echo "Waiting for Ollama API..." >&2
          sleep 3
        done
        ${concatMapStringsSep "\n" (model: ''
          # ollama list prints "NAME ID SIZE MODIFIED" with the model name at
          # column 1 (e.g. "llama3.2:latest"). A bare name in prePullModels
          # implicitly maps to ":latest", so grep at start-of-line is enough.
          if ! ollama list 2>/dev/null | grep -q "^${model}"; then
            echo "Pre-pulling model: ${model}" >&2
            ollama pull "${model}" 2>&1 || echo "Failed to pull ${model} (will retry on next boot)" >&2
          else
            echo "Model already present: ${model}" >&2
          fi
        '') cfg.prePullModels}
      '';
    };

    systemd.services.openclaw = mkIf isOpenclaw {
      description = "Nyxorn — OpenClaw AI Assistant Gateway";
      after    = [ "network.target" ]
                 ++ optional cfg.ollama.enable "ollama.service"
                 ++ optional (cfg.ollama.enable && cfg.prePullModels != [ ]) "nyxorn-prepull.service";
      wants    = optional cfg.ollama.enable "ollama.service"
                 ++ optional (cfg.ollama.enable && cfg.prePullModels != [ ]) "nyxorn-prepull.service";
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;

      path = with pkgs; [ bash coreutils gnugrep iproute2 ] ++ openclawTools
             ++ optional cfg.ollama.enable cfg.ollama.package;

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
        ReadWritePaths = [ nyxornHome "/var/log/nyxorn" ]
                       ++ optional cfg.ollama.enable "/var/lib/ollama";
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

          ${optionalString cfg.ollama.enable ''
          until ollama list > /dev/null 2>&1; do
            echo "Waiting for Ollama to become ready..." >&2
            sleep 3
          done
          echo "Ollama is ready." >&2
          ''}

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
    ] ++ optionals isOpenclaw [
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
          secret_key = cfg.searxng.secretKey;
        };
        search = {
          safe_search = 0;
          default_lang = "en";
          # SearXNG disables non-HTML output by default and returns 403 for
          # ?format=json, which breaks every machine client (OpenClaw's
          # ClawHub bridge, Sekurvia, MCP servers, plain curl, …). Enable
          # both so HTML browsing AND machine clients work against the same
          # instance.
          formats = [ "html" "json" ];
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

    environment.systemPackages = [ nyxornDebugScript ]
                              ++ optionals isOpenclaw openclawTools
                              ++ optional  isHermes   hermesOnboardStub;

    programs.zsh.enable = true;
    programs.bash.completion.enable = true;

    environment.shellAliases =
      let
        # OpenClaw-only env (Hermes uses settings.model.base_url directly).
        # OLLAMA_API_KEY in particular must NOT be set for the Hermes path:
        # its presence biases Hermes' provider auto-detection toward the
        # *ollama-cloud* provider (ollama.com/v1) instead of our local
        # endpoint, and the local key value would then fail with HTTP 401.
        openclawOllamaEnv = "OLLAMA_HOST=http://localhost:11434 OLLAMA_API_KEY=ollama-local";
        workspace  = "${nyxornHome}/workspace";

        openclawCmd = "sudo -u nyxorn-agent env HOME=${nyxornHome} PATH=${npmGlobalPrefix}/bin:/run/current-system/sw/bin:$PATH ${openclawOllamaEnv} openclaw";

        # Hermes scans upward from $CWD looking for a git repo, so we land
        # inside a directory the nyxorn-agent user can read before exec'ing
        # the binary — otherwise it tries to stat /home/<you>/.git and crashes
        # with EACCES. The bash -c trick lets us cd, then forward "$@" to hermes.
        hermesCmd   = "sudo -u nyxorn-agent env HOME=${nyxornHome} bash -c 'cd ${workspace} 2>/dev/null || cd /tmp; exec hermes \"$@\"' nyxorn-cli";

        nyxornCmd        = if isHermes then hermesCmd else openclawCmd;
        onboardCmd       = if isHermes then "nyxorn-onboard-hermes" else "${openclawCmd} onboard";
        logsCmd          = if isHermes then "sudo journalctl -u hermes-agent -f"           else "sudo tail -f /var/log/nyxorn/openclaw.log";
        errorsCmd        = if isHermes then "sudo journalctl -u hermes-agent -p err -f"   else "sudo tail -f /var/log/nyxorn/openclaw-error.log";
        journalUnits     = (if cfg.ollama.enable then "ollama " else "") + agentService;
        statusUnits      = (if cfg.ollama.enable then "ollama " else "") + agentService;
      in
      {
        nyxorn          = nyxornCmd;
        nyxorn-onboard  = onboardCmd;
        nyxorn-debug    = "sudo nyxorn-debug";
        nyxorn-logs     = logsCmd;
        nyxorn-errors   = errorsCmd;
        nyxorn-journal  = "sudo journalctl -u ${journalUnits} -f";
        nyxorn-restart  = "sudo systemctl restart ${agentService}";
        nyxorn-stop     = "sudo systemctl stop ${agentService}";
        nyxorn-start    = "sudo systemctl start ${agentService}";
        nyxorn-status   = "systemctl status ${statusUnits}";
      };

    services.logrotate = mkIf isOpenclaw {
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

    # ── Hermes engine ──────────────────────────────────────────────────────
    # Wires the upstream services.hermes-agent module against the existing
    # nyxorn-agent user / state dir, and auto-injects sensible defaults so
    # local-Ollama and SearXNG users get a working setup with zero config.
    services.hermes-agent = mkIf isHermes (
      let
        userSettings  = cfg.hermes.settings;
        userModel     = userSettings.model    or { };
        userTerminal  = userSettings.terminal or { };

        hasModelBaseUrl  = userModel    ? base_url;
        hasModelDefault  = userModel    ? default;
        hasModelProvider = userModel    ? provider;
        hasTerminalCwd   = userTerminal ? cwd;

        # Only inject keys the user didn't already set; recursiveUpdate then
        # merges the partial overrides onto userSettings without clobbering
        # anything user-defined.
        #
        # Important: for local Ollama via the OpenAI-compatible endpoint,
        # we must also set provider = "custom". Without it, Hermes resolves
        # bare model names (e.g. "llama3.2") against its built-in catalog
        # and routes them to the *ollama-cloud* provider at ollama.com/v1,
        # producing an HTTP 401. With provider = "custom", the OpenAI SDK
        # talks directly to base_url. See
        # https://hermes-agent.nousresearch.com/docs/integrations/providers
        autoModel =
          (optionalAttrs (cfg.ollama.enable && !hasModelBaseUrl) {
            base_url = "http://localhost:11434/v1";
          }) //
          (optionalAttrs (cfg.ollama.enable && !hasModelProvider && !hasModelBaseUrl) {
            provider = "custom";
          }) //
          (optionalAttrs (cfg.defaultModel != null && !hasModelDefault) {
            default = cfg.defaultModel;
          });

        # Pin the gateway/cron working directory to the agent's workspace.
        # Without this, the messaging gateway defaults to "~" (= the agent's
        # HOME = /var/lib/nyxorn-agent), which is fine, but Hermes scans
        # upward for a git repo and may try to read paths the nyxorn-agent
        # user can't access. Anchoring at workspace gives it a quiet, owned
        # directory to run in. CLI launches still respect $CWD.
        autoTerminal = optionalAttrs (!hasTerminalCwd) {
          cwd = "${nyxornHome}/workspace";
        };

        autoOverrides =
          (optionalAttrs (autoModel    != { }) { model    = autoModel;    }) //
          (optionalAttrs (autoTerminal != { }) { terminal = autoTerminal; });

        mergedSettings =
          if autoOverrides == { } then userSettings
          else recursiveUpdate userSettings autoOverrides;

        # Auto-injected non-secret env vars for the systemd service. Always
        # additive — user-supplied hermes.environment wins on conflicts.
        autoEnv = optionalAttrs cfg.enableSearxng {
          SEARXNG_URL = cfg.searxng.url;
        };

        mergedEnv = autoEnv // cfg.hermes.environment;
      in
      {
        enable = true;
        # nyxorn already owns the user / group / home — don't let upstream
        # double-create them, and reuse the existing state directory so
        # nyxorn-debug, /var/log/nyxorn, and shell aliases all keep working.
        user        = "nyxorn-agent";
        group       = "nyxorn-agent";
        createUser  = false;
        stateDir    = nyxornHome;

        addToSystemPackages    = cfg.hermes.addToSystemPackages;
        environmentFiles       = cfg.hermes.environmentFiles;
        environment            = mergedEnv;
        mcpServers             = cfg.hermes.mcpServers;
        documents              = cfg.hermes.documents;
        extraPlugins           = cfg.hermes.extraPlugins;
        extraPythonPackages    = cfg.hermes.extraPythonPackages;
        extraPackages          = cfg.hermes.extraPackages;
        authFile               = cfg.hermes.authFile;
        authFileForceOverwrite = cfg.hermes.authFileForceOverwrite;
        extraArgs              = cfg.hermes.extraArgs;
        restart                = cfg.hermes.restart;
        restartSec             = cfg.hermes.restartSec;

        settings   = mergedSettings;
        configFile = cfg.hermes.configFile;

        container = {
          enable       = cfg.hermes.container.enable;
          backend      = cfg.hermes.container.backend;
          image        = cfg.hermes.container.image;
          extraVolumes = cfg.hermes.container.extraVolumes;
          extraOptions = cfg.hermes.container.extraOptions;
          hostUsers    = cfg.hermes.container.hostUsers;
        };
      }
    );

    # Order Hermes after the model pre-pull so first-chat doesn't 404 on a
    # missing tag. Only adds a dependency when both engines and prePull are
    # active — otherwise it's a no-op.
    systemd.services.hermes-agent = mkIf (isHermes && cfg.ollama.enable && cfg.prePullModels != [ ]) {
      after    = [ "nyxorn-prepull.service" ];
      wants    = [ "nyxorn-prepull.service" ];
    };

    # Declarative Hermes skill bundles. Mirrors upstream's extraPlugins
    # symlink approach but supports nested category paths under skills/
    # (research/foo, devops/bar, …) and tracks managed entries via a
    # state file so removals from config are cleaned up on rebuild.
    system.activationScripts."nyxorn-hermes-skills" = mkIf isHermes (
      lib.stringAfter [ "hermes-agent-setup" ] ''
        skillsDir="${nyxornHome}/.hermes/skills"
        stateFile="${nyxornHome}/.hermes/.nyxorn-skills.list"

        mkdir -p "$skillsDir"
        chown nyxorn-agent:nyxorn-agent "$skillsDir" 2>/dev/null || true

        # Remove any symlinks managed by a previous activation that aren't
        # in the current config.
        if [ -f "$stateFile" ]; then
          while IFS= read -r prevPath; do
            [ -z "$prevPath" ] && continue
            target="$skillsDir/$prevPath"
            if [ -L "$target" ]; then
              rm -f "$target"
            fi
          done < "$stateFile"
        fi

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: source: ''
          if [ ! -f "${source}/SKILL.md" ]; then
            echo "ERROR: services.aiAgent.hermes.skills.\"${name}\" — no SKILL.md at ${source}" >&2
            exit 1
          fi
          install -d -o nyxorn-agent -g nyxorn-agent -m 2770 "$(dirname "$skillsDir/${name}")"
          ln -sfn "${source}" "$skillsDir/${name}"
          chown -h nyxorn-agent:nyxorn-agent "$skillsDir/${name}"
        '') cfg.hermes.skills)}

        cat > "$stateFile" <<'NYXORN_SKILLS_LIST_EOF'
${lib.concatStringsSep "\n" (lib.attrNames cfg.hermes.skills)}
NYXORN_SKILLS_LIST_EOF
        chown nyxorn-agent:nyxorn-agent "$stateFile" 2>/dev/null || true
        chmod 0640 "$stateFile" 2>/dev/null || true
      ''
    );
  };
}
