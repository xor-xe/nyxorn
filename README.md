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
inputs.nyxorn.url = "github:youruser/nyxorn";
```

Import the module and enable it:

```nix
nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
  modules = [
    nyxorn.nixosModules.default
    {
      services.aiAgent.enable = true;

      # GPU acceleration: "cuda" (NVIDIA), "rocm" (AMD), "vulkan" (Intel Arc), "auto" (CPU)
      services.aiAgent.gpuAcceleration = "cuda";

      # Pre-pull Ollama models on service start
      services.aiAgent.prePullModels = [ "llama3.2" ];

      # Install ClawHub skills declaratively
      services.aiAgent.clawhubSkills = [
        "ivangdavila/self-improving"
      ];

      # Optional: local SearXNG for free web search
      services.aiAgent.enableSearxng = true;
      services.searx.settings.server.secret_key = "your-random-secret";
    }
  ];
};
```

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable the nyxorn AI agent stack |
| `gpuAcceleration` | enum | `"auto"` | GPU backend: `auto`, `cuda`, `rocm`, `vulkan`, `cpu` |
| `prePullModels` | list | `[]` | Ollama models to pre-pull on service start |
| `defaultModel` | string | `null` | Default model passed to OpenClaw |
| `ollama.package` | package | auto | Override the Ollama package (e.g. custom build) |
| `enableSearxng` | bool | `false` | Run a local SearXNG instance on port 8888 |
| `searxng.url` | string | `http://127.0.0.1:8888` | SearXNG URL passed to OpenClaw |
| `clawhubSkills` | list | `[]` | ClawHub skill slugs to install automatically |

## First-time setup

After the first `nixos-rebuild switch`, run onboarding to configure Ollama as the provider:

```bash
nyxorn-onboard --skip-health
nyxorn-restart
```

Then open `http://localhost:18789` in your browser.

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

## Updating

**Ollama** (gets latest from nixos-unstable):
```bash
cd ~/dotfiles
nix flake update nyxorn
sudo nixos-rebuild switch --flake .#nixos
sudo systemctl restart ollama
```

**OpenClaw** (reinstalls latest from npm):
```bash
sudo rm -rf /var/lib/nyxorn-agent/.npm-global/lib/node_modules/openclaw
nyxorn-restart
```

**Nyxorn module itself**:
```bash
cd ~/dotfiles
nix flake update nyxorn
sudo nixos-rebuild switch --flake .#nixos
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
