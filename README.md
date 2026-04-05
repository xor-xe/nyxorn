# nyxorn

A NixOS module that layers an AI agent stack on top of any existing NixOS configuration. It runs [OpenClaw](https://openclaw.ai) as an isolated service user (`nyxorn-agent`), backed by [Ollama](https://ollama.ai) for local LLM inference with optional GPU acceleration.

## What it does

- Creates a locked-down `nyxorn-agent` system user
- Runs Ollama with automatic GPU support (CUDA, ROCm, Vulkan)
- Installs and runs the latest OpenClaw gateway via npm
- Exposes the OpenClaw UI at `http://localhost:18789`
- Optionally runs a local SearXNG instance for free web search
- Declaratively installs [ClawHub](https://clawhub.ai) skills
- Provides `nyxorn-*` shell aliases for common operations

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

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the nyxorn AI agent stack |
| `ollama.enable` | bool | `true` | Run a local Ollama instance. Set `false` to use OpenClaw only (remote/cloud backend) |
| `ollama.channel` | enum | `"unstable"` | nixpkgs source for Ollama: `"unstable"` (safe, 1-3 days behind master) or `"master"` (bleeding edge, same-day updates). Has no effect when `ollama.enable = false` |
| `ollama.package` | package | auto | Override the Ollama package (advanced). Has no effect when `ollama.enable = false` |
| `gpuAcceleration` | enum | `"cpu"` | GPU backend: `cpu`, `cuda`, `rocm`, `vulkan`. Requires `ollama.enable = true` |
| `prePullModels` | list | `[]` | Ollama models to pre-pull on service start. Requires `ollama.enable = true` |
| `defaultModel` | string | `null` | Default model passed to OpenClaw |
| `enableSearxng` | bool | `false` | Run a local SearXNG instance on port 8888 |
| `searxng.url` | string | `http://127.0.0.1:8888` | SearXNG URL passed to OpenClaw |
| `searxng.secretKey` | string | — | **Required** when `enableSearxng = true`. Generate: `openssl rand -hex 32` |
| `clawhubSkills` | list | `[]` | ClawHub skill slugs to install automatically |

## First-time setup

After the first `nixos-rebuild switch`, reboot and run onboarding to configure Ollama as the provider:

```bash
nyxorn-onboard --skip-health
nyxorn-restart
```

Then run ``nyxorn dashboard`` and open it in your browser.

## Shell aliases

| Alias | Description |
|---|---|
| `nyxorn-status` | Show status of Ollama and OpenClaw services |
| `nyxorn-onboard` | Run first-time provider setup |
| `nyxorn-restart` | Restart the OpenClaw gateway |
| `nyxorn-start` | Start the OpenClaw gateway |
| `nyxorn-stop` | Stop the OpenClaw gateway |
| `nyxorn-logs` | Follow the OpenClaw stdout log |
| `nyxorn-errors` | Follow the OpenClaw stderr log |
| `nyxorn-journal` | Live journald output for Ollama + OpenClaw |
| `nyxorn-debug` | Full diagnostic (services, ports, models, logs) |
| `nyxorn <cmd>` | Run any OpenClaw command as `nyxorn-agent` |

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
| `/var/lib/nyxorn-agent/.openclaw/` | OpenClaw config and state |
| `/var/lib/nyxorn-agent/.openclaw/skills/` | Installed skills |
| `/var/lib/nyxorn-agent/.npm-global/` | npm-installed OpenClaw binary |
| `/var/log/nyxorn/` | OpenClaw logs |

## Installing skills manually

```bash
sudo -u nyxorn-agent mkdir -p /var/lib/nyxorn-agent/.openclaw/skills/my-skill
sudo unzip ~/Downloads/skill.zip -d /var/lib/nyxorn-agent/.openclaw/skills/my-skill/
sudo chown -R nyxorn-agent:nyxorn-agent /var/lib/nyxorn-agent/.openclaw/skills/
nyxorn-restart
```

Browse skills at [clawhub.ai](https://clawhub.ai).
