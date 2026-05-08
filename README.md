# nyxorn

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A NixOS module that layers an AI agent stack on top of any existing NixOS configuration. It runs your choice of agent engine — [OpenClaw](https://openclaw.ai) (default) or [Hermes Agent](https://github.com/NousResearch/hermes-agent) — as an isolated service user (`nyxorn-agent`), backed by [Ollama](https://ollama.ai) for local LLM inference with optional GPU acceleration.

## What it does

- Creates a locked-down `nyxorn-agent` system user
- Runs Ollama with automatic GPU support (CUDA, ROCm, Vulkan)
- Runs **one** of two agent engines per host (mutually exclusive):
  - **OpenClaw** (default) — npm-installed gateway on `http://localhost:18789`, ClawHub skill auto-install, interactive `openclaw onboard` setup
  - **Hermes** — declarative NousResearch agent module (settings, MCP servers, plugins, documents) with optional persistent Ubuntu container for self-modification
- Optionally runs a local SearXNG instance and exposes it as `SEARXNG_URL` to the active engine — OpenClaw bridges it via ClawHub; Hermes consumes it through any plugin that reads `SEARXNG_URL` (e.g. [Sekurvia](https://github.com/xor-xe/Sekurvia))
- Provides `nyxorn-*` shell aliases that auto-target the active engine

## Picking an engine

| Engine | Best for | Config style | Ships with |
|---|---|---|---|
| `openclaw` (default) | Plug-and-play UI, ClawHub skills, interactive setup | Imperative CLI (`openclaw onboard`) | OpenClaw npm gateway, port 18789 |
| `hermes` | Declarative agent definition, MCP-first workflows, self-modifying agents | Pure Nix (`services.aiAgent.hermes.settings`) | Hermes Agent + uv2nix-built deps, optional Ubuntu container |

## Usage

Add nyxorn as a flake input:

```nix
inputs.nyxorn.url = "github.com/xor-xe/nyxorn";
```

Import the module and enable it:

**With local Ollama** (default):
```nix
services.aiAgent = {
  enable = true;
  gpuAcceleration = "cuda";          # "rocm" AMD · "vulkan" Intel Arc · "cpu" default
  ollama.channel = "master";         # "unstable" default · "master" for same-day releases
  prePullModels = [ "llama3.2" ];
  clawhubSkills = [ "ivangdavila/self-improving" ];
  enableSearxng = true;
  searxng.secretKey = "<openssl rand -hex 32>";
};
```

**OpenClaw only** (no local Ollama — configure a remote/cloud backend via `nyxorn-onboard`):
```nix
services.aiAgent = {
  enable = true;
  ollama.enable = false;
  clawhubSkills = [ "ivangdavila/self-improving" ];
};
```

**Hermes engine with local Ollama** (declarative, no interactive setup):
```nix
services.aiAgent = {
  enable = true;
  engine = "hermes";
  gpuAcceleration = "cuda";
  defaultModel = "llama3.2";              # auto-injected as model.default
  hermes.settings = {
    toolsets = [ "all" ];
    memory.memory_enabled = true;
  };
  # Local Ollama wins by default. base_url is auto-set to
  # http://localhost:11434/v1 when ollama.enable = true.
};
```

**Hermes engine with a remote provider + persistent container**:
```nix
{ config, ... }: {
  services.aiAgent = {
    enable = true;
    engine = "hermes";
    ollama.enable = false;
    hermes = {
      settings.model.default = "anthropic/claude-sonnet-4";
      environmentFiles = [ config.sops.secrets."hermes-env".path ];
      container.enable = true;            # Ubuntu container, agent can apt/pip/npm install
      container.hostUsers = [ "you" ];    # share ~/.hermes with your shell
    };
  };
}
```

## Options

### Core

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the nyxorn AI agent stack |
| `engine` | enum | `"openclaw"` | Which agent engine to run: `"openclaw"` or `"hermes"`. Engines are mutually exclusive per host |
| `ollama.enable` | bool | `true` | Run a local Ollama instance. Set `false` to point the engine at a remote/cloud backend |
| `ollama.channel` | enum | `"unstable"` | nixpkgs source for Ollama: `"unstable"` (safe, 1-3 days behind master) or `"master"` (bleeding edge, same-day updates). Has no effect when `ollama.enable = false` |
| `ollama.package` | package | auto | Override the Ollama package (advanced). Has no effect when `ollama.enable = false` |
| `gpuAcceleration` | enum | `"cpu"` | GPU backend: `cpu`, `cuda`, `rocm`, `vulkan`. Requires `ollama.enable = true` |
| `prePullModels` | list | `[]` | Ollama models to pre-pull on service start. Requires `ollama.enable = true` |
| `defaultModel` | string | `null` | Default model. For OpenClaw: passed via CLI. For Hermes: auto-injected as `settings.model.default` if user didn't set it |
| `enableSearxng` | bool | `false` | Run a local SearXNG instance on port 8888 (shared by either engine) |
| `searxng.url` | string | `http://127.0.0.1:8888` | SearXNG URL. Exposed as `SEARXNG_URL` env var to OpenClaw and Hermes. For Hermes, a plugin that reads `SEARXNG_URL` (e.g. [Sekurvia](https://github.com/xor-xe/Sekurvia)) is required to actually use it |
| `searxng.secretKey` | string | — | **Required** when `enableSearxng = true`. Generate: `openssl rand -hex 32` |
| `clawhubSkills` | list | `[]` | ClawHub skill slugs to install automatically. **OpenClaw only** — assertion fails if set with `engine = "hermes"` |
| `openclawChannelPlugins` | attrs of lists | `{}` | Per-channel plugin activation. Keys are channel names (e.g. `"telegram"`), values are skill basenames. See [Per-channel plugin activation](#per-channel-plugin-activation-openclaw). **OpenClaw only** |

### Hermes engine (`services.aiAgent.hermes.*`)

All Hermes options are passthroughs onto upstream `services.hermes-agent`. They take effect only when `engine = "hermes"`.

| Option | Type | Default | Description |
|---|---|---|---|
| `hermes.settings` | attrs | `{}` | Declarative `config.yaml`. Deep-merged with auto-injected defaults (Ollama base_url, defaultModel) |
| `hermes.configFile` | path | `null` | Escape hatch — replaces `settings` entirely with a hand-written file |
| `hermes.environmentFiles` | list of paths | `[]` | Files containing API keys / secrets. Use sops-nix or agenix |
| `hermes.environment` | attrs of str | `{}` | Non-secret env vars (visible in /nix/store) |
| `hermes.mcpServers` | attrs | `{}` | MCP server definitions (stdio or HTTP) |
| `hermes.documents` | attrs | `{}` | Files installed into the agent workspace (e.g. `USER.md`) |
| `hermes.extraPlugins` | list | `[]` | Directory plugins symlinked into `$HERMES_HOME/plugins/` |
| `hermes.extraPythonPackages` | list | `[]` | Entry-point plugin packages (added to PYTHONPATH) |
| `hermes.skills` | attrs | `{}` | Skill bundles symlinked into `$HERMES_HOME/skills/<key>`. Keys are `<category>/<name>` paths; values point at a directory containing `SKILL.md`. Stale entries are cleaned up on rebuild |
| `hermes.extraPackages` | list | `[]` | Extra system packages available to the agent |
| `hermes.authFile` | path | `null` | OAuth credentials seed file |
| `hermes.authFileForceOverwrite` | bool | `false` | Re-seed `auth.json` on every activation |
| `hermes.addToSystemPackages` | bool | `true` | Add `hermes` CLI to system PATH and set `HERMES_HOME` system-wide |
| `hermes.extraArgs` | list | `[]` | Extra args appended to `hermes gateway` |
| `hermes.restart` / `hermes.restartSec` | str / int | `"always"` / `5` | systemd restart policy |
| `hermes.container.enable` | bool | `false` | Run Hermes in a persistent Ubuntu container (lets the agent `apt`/`pip`/`npm install`) |
| `hermes.container.backend` | enum | `"docker"` | `"docker"` or `"podman"` |
| `hermes.container.image` | string | `"ubuntu:24.04"` | Base OCI image |
| `hermes.container.extraVolumes` | list | `[]` | Extra volume mounts (`host:container[:mode]`) |
| `hermes.container.extraOptions` | list | `[]` | Extra args to `docker create` (e.g. `[ "--gpus" "all" ]`) |
| `hermes.container.hostUsers` | list | `[]` | Users who get a `~/.hermes` symlink and join the `nyxorn-agent` group |

## First-time setup

### OpenClaw (default engine)

After the first `nixos-rebuild switch`, reboot and run onboarding to configure Ollama as the provider:

```bash
nyxorn-onboard --skip-health
nyxorn-restart
```

Then run `nyxorn dashboard` and open it in your browser.

### Hermes engine

No interactive setup. Hermes runs in **managed mode** — `hermes setup` and `hermes config edit` are intentionally blocked because the configuration is generated from your NixOS config. After `nixos-rebuild switch`:

```bash
systemctl status hermes-agent          # or: nyxorn-status
journalctl -u hermes-agent -f          # or: nyxorn-logs
hermes version                          # if hermes.addToSystemPackages = true (default)
```

If you forget how to configure Hermes from a fresh shell, run `nyxorn-onboard` — it prints a short pointer to the relevant Nix options.

## Secrets (Hermes only)

Hermes needs a provider key whenever it isn't talking to local Ollama. Keys must come from a file outside `/nix/store`. Recommended setups:

- **[sops-nix](https://github.com/Mic92/sops-nix)** — encrypted YAML/JSON committed to the repo, decrypted at activation.
- **[agenix](https://github.com/ryantm/agenix)** — age-encrypted files, similar workflow.

Wire them into the agent via:

```nix
services.aiAgent.hermes.environmentFiles = [
  config.sops.secrets."hermes-env".path
];
```

Where the secret payload contains lines like `OPENROUTER_API_KEY=sk-or-...` and `ANTHROPIC_API_KEY=sk-ant-...`.

A bare-minimum bootstrap (not for production) is a 0600 plain file:

```bash
echo "OPENROUTER_API_KEY=sk-or-your-key" \
  | sudo install -m 0600 -o nyxorn-agent /dev/stdin /var/lib/nyxorn-agent/hermes-env
```

```nix
services.aiAgent.hermes.environmentFiles = [ "/var/lib/nyxorn-agent/hermes-env" ];
```

## Shell aliases

All `nyxorn-*` aliases auto-target the active engine (OpenClaw or Hermes).

| Alias | Description |
|---|---|
| `nyxorn-status` | Show status of Ollama and the active agent service |
| `nyxorn-onboard` | OpenClaw: run interactive setup. Hermes: print declarative-config pointer |
| `nyxorn-restart` | Restart the active agent service (`openclaw` or `hermes-agent`) |
| `nyxorn-start` | Start the active agent service |
| `nyxorn-stop` | Stop the active agent service |
| `nyxorn-logs` | Follow stdout / journald for the active agent |
| `nyxorn-errors` | Follow stderr / error-priority journal entries |
| `nyxorn-journal` | Live journald output for Ollama + the active agent |
| `nyxorn-debug` | Full diagnostic (services, ports, models, logs) |
| `nyxorn <cmd>` | Run any OpenClaw / Hermes command as `nyxorn-agent` |

## Keeping Ollama up to date

Nyxorn carries **two nixpkgs snapshots** and you choose which one Ollama is pulled from:

| `ollama.channel` | Source | Lag behind releases |
|---|---|---|
| `"unstable"` (default) | `nixpkgs-unstable` | 1–3 days — well-tested, recommended for most |
| `"master"` | `nixpkgs master` | Same day — bleeding edge, use for very new models |

### Use bleeding-edge Ollama (e.g. for gemma4 or any newly released model)

```nix
services.aiAgent.ollama.channel = "master";
```

That's it. Rebuild and Ollama will come from nixpkgs master, which always has the
latest packaged release.

### Keep both snapshots current

Both `nixpkgs` (unstable) and `nixpkgs-master` are updated together when you run:

```bash
# In your system dotfiles repo
nix flake update nyxorn
sudo nixos-rebuild switch --flake .#yourhost
sudo systemctl restart ollama
```

### Tie Ollama to your system's nixpkgs (optional)

If you want Ollama to follow your system's nixpkgs instead of nyxorn's own snapshot,
add this to your system `flake.nix`:

```nix
inputs.nyxorn = {
  url = "github:xor-xe/nyxorn";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

---

**OpenClaw** (reinstalls latest from npm):
```bash
sudo rm -rf /var/lib/nyxorn-agent/.npm-global/lib/node_modules/openclaw
nyxorn-restart
```

**Hermes** (pin to a tagged release in your system flake):
```nix
inputs.nyxorn.inputs.hermes-agent.url = "github:NousResearch/hermes-agent/v2026.4.30";
```
or update along with everything else:
```bash
nix flake update nyxorn
sudo nixos-rebuild switch --flake .#yourhost
```

**Nyxorn module itself**:
```bash
cd ~/dotfiles
nix flake update nyxorn
sudo nixos-rebuild switch --flake .#yourhost
```

## State locations

| Path | Contents |
|---|---|
| `/var/lib/nyxorn-agent/` | Agent home directory |
| `/var/lib/nyxorn-agent/.openclaw/` | OpenClaw config and state (`openclaw.json`) |
| `/var/lib/nyxorn-agent/.openclaw/plugin-skills/` | ClawHub skills installed via `clawhubSkills` |
| `/var/lib/nyxorn-agent/.npm-global/` | npm-installed OpenClaw binary |
| `/var/log/nyxorn/` | OpenClaw logs |

## Installing skills manually (OpenClaw)

```bash
sudo -u nyxorn-agent mkdir -p /var/lib/nyxorn-agent/.openclaw/plugin-skills/my-skill
sudo unzip ~/Downloads/skill.zip -d /var/lib/nyxorn-agent/.openclaw/plugin-skills/my-skill/
sudo chown -R nyxorn-agent:nyxorn-agent /var/lib/nyxorn-agent/.openclaw/plugin-skills/
nyxorn-restart
```

Browse skills at [clawhub.ai](https://clawhub.ai).

> **Tip:** prefer declaring skills in `clawhubSkills` and activating them per-channel via
> `openclawChannelPlugins` so the configuration survives rebuilds without manual intervention.

## Per-channel plugin activation (OpenClaw)

OpenClaw tracks which plugins are active per-channel inside `openclaw.json`. The control-ui
channel enumerates all installed skills automatically, but non-UI channels (Telegram, Discord,
Slack, …) only expose the tools their channel config explicitly lists.

Use `openclawChannelPlugins` to declare which skills each channel should have access to.
On every gateway restart nyxorn patches `openclaw.json` so the entries are always present —
existing config is preserved and duplicates are removed.

The key is the channel name exactly as it appears in `openclaw.json`; the values are the
**basenames** of your `clawhubSkills` slugs (the part after the `/`).

```nix
services.aiAgent = {
  enable = true;
  clawhubSkills = [ "genortg/openclaw-comfyui-api-runner" ];

  openclawChannelPlugins = {
    telegram = [ "openclaw-comfyui-api-runner" ];
    discord  = [ "openclaw-comfyui-api-runner" ];
  };
};
```

After rebuilding, restart the service to apply the patch immediately:

```bash
sudo nixos-rebuild switch
nyxorn-restart
```

If a channel listed here doesn't exist yet in `openclaw.json` (e.g. you haven't connected
Telegram yet), the entry is silently skipped and logged as `[SKIP]` — it takes effect
automatically the next time the gateway restarts after the channel is set up.

## Installing plugins and skills (Hermes)

Hermes has three extension points; nyxorn exposes a declarative slot for each.

| Kind | Option | What it ships |
|---|---|---|
| Directory plugin | `hermes.extraPlugins` | `plugin.yaml` + `__init__.py` Python package |
| Entry-point plugin | `hermes.extraPythonPackages` | wheel-installable plugin via `hermes_agent.plugins` entry point |
| Skill bundle | `hermes.skills` | `SKILL.md` + helper scripts that the agent loads on demand |

### Plugin example

```nix
services.aiAgent.hermes = {
  extraPlugins = [
    (pkgs.fetchFromGitHub {
      owner = "stephenschoettler";
      repo  = "hermes-lcm";
      rev   = "v0.7.0";
      hash  = "sha256-...";
    })
  ];
  settings.plugins.enabled = [ "hermes-lcm" ];
};
```

### Web search via Sekurvia (skill) + local SearXNG

Hermes has no built-in general web-search tool. Pair `enableSearxng = true` with [Sekurvia](https://github.com/xor-xe/Sekurvia) — a SKILL.md bundle that wraps the `SEARXNG_URL` nyxorn already injects:

```nix
services.aiAgent = {
  enable = true;
  engine = "hermes";

  enableSearxng = true;
  searxng.secretKey = "<openssl rand -hex 32>";

  hermes.skills."research/searxng-search" =
    (pkgs.fetchFromGitHub {
      owner = "xor-xe";
      repo  = "Sekurvia";
      rev   = "main";          # or pin a tagged release
      hash  = "sha256-...";
    }) + "/searxng-search";
};
```

The skill auto-hides itself when Hermes' built-in `web_search` tool is enabled (via `fallback_for_toolsets: [web]`), so it stays out of the way for users who wire up a SaaS web tool. See [Sekurvia's README](https://github.com/xor-xe/Sekurvia#configuration) for the optional `SEKURVIA_*` knobs.
