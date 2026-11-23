# ai-sandbox

Ephemeral, disposable coding environments for AI agents — one clean Lima VM
on your Mac, Docker inside it, and per-flavor sysbox containers where
agents run wild without touching anything that matters.

```
┌─ macOS (Apple Silicon) ──────────────────────────────────────────────┐
│  ~/ai-projects/<proj>            ~/.ai-secrets/  (0600)              │
│      │ source of truth                 │ real API keys (only copy)  │
│      │ virtiofs (writable)             │ ro share → VM at boot     │
│  ┌───▼──────────────────────────────────▼───────────────────────┐   │
│  │ Lima VM "ai-box"  (vz, Ubuntu 24.04, appliance)              │   │
│  │   outer dockerd ── registry mirror :5000 ── gateway :4000    │   │
│  │        │ runtime: sysbox-runc (rootless user-ns)             │   │
│  │   ┌────┴──────────┐  ┌───────────────┐  ┌───────────────┐    │   │
│  │   │ sandbox proj-a │  │ sandbox proj-b│  │ sandbox ...   │    │   │
│  │   │ inner dockerd  │  │ inner dockerd │  │               │    │   │
│  │   │ OpenCode/dsh   │  │ OpenCode/dsh  │  │               │    │   │
│  │   │ dummy keys only│  │               │  │               │    │   │
│  │   └───────────────┘  └───────────────┘  └───────────────┘    │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

## Why this shape

- **One VM, many containers** — containers share one kernel, one RAM pool
  and one image cache; N VMs (Vagrant-style) fragment memory and duplicate
  everything.
- **Agents in sysbox containers, never on the VM** — each sandbox is a
  rootless user-namespace "system container": the agent has real root
  *inside* (apt install works) with a private docker daemon and network
  namespace, and maps to an unprivileged UID on the VM. No
  `privileged: true` anywhere. The VM itself stays agent-less.
- **Ephemeral by tier** — fresh container OS every `just shell`; source,
  build caches and inner images persist in per-flavor volumes; the whole
  VM is reproducible from one YAML.
- **Keys never enter a sandbox** — for gateway-routed providers, agents
  hold format-valid dummy keys; a protocol-blind gateway on the VM swaps
  them for real keys in transit. It forwards OpenCode Go's
  OpenAI/Anthropic/Gemini traffic untouched, and DeepSeek's official API
  untouched. No per-model or per-protocol gateway logic. Direct BYOK is
  the explicit exception (see the OpenCode flavor notes).
- **Update-friendly** — image layers are ordered by churn so weekly agent
  CLI bumps rebuild in minutes (`just bump-agents && just build`).

Full rationale, trade-offs and the alternatives that were rejected
(Docker `sbx`, DinD sidecars on the host daemon, per-project VMs):
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Flavors

Three image flavors, **identical toolchains** (node/typescript, rust,
python, go + the usual utils: jq, tmux, ripgrep, fd, fzf, bat, git, inner
docker) — two carry an agent CLI, one carries none:

| Flavor | Suffix | Agent | Default provider (via gateway) |
| --- | --- | --- | --- |
| `ai-opencode` | — | OpenCode TUI | DeepSeek official (baked default); OpenCode Go available |
| `ai-deepseek` | `-dsh` | DeepSeek Harness (dsh) web UI | DeepSeek official API |
| `ai-whiteboard` | `-clean` | — none — | any, ad-hoc (npx/uv/curl whatever the task needs) |

DeepSeek official is the baked default for `ai-opencode`: the config
endpoint-overrides the catalog `deepseek` provider onto the same
`/deepseek` route the dsh flavor uses. OpenCode Go is wired the same way
via `/opencode-go`; pick either in `/models`, and the gateway swaps the
dummy for your real key in transit (no second route, no key in the
sandbox).

**Flavors are per-invocation, not per-project**: the flavor is a suffix
on the project name — `just up proj-alpha` runs the OpenCode sandbox,
`just up proj-alpha-dsh` the DeepSeek Harness one, `just up
proj-alpha-clean` the agent-free whiteboard one, all mounting the same
`~/ai-projects/proj-alpha` dir. They coexist as separate compose
projects (disjoint containers, volumes, networks); `.sandbox.env` stays
one flavor-agnostic file.

The OpenCode flavor is also the base harness for third-party providers:
use OpenCode's native provider catalog with direct BYOK, or add a
gateway-isolated route if you care about that provider's key. The
commented route template lives in `gateway/Caddyfile`; step-by-step usage
and the matching OpenCode provider config are in
[docs/AGENT-CONFIG.md](docs/AGENT-CONFIG.md).

## Quickstart (on the Mac)

```bash
brew install lima just
cp -R <this-repo> ~/ai-projects/ai-sandbox

just vm-up                    # create + provision the VM (first run ~5 min)
just build                    # build base + whiteboard/opencode/deepseek
just verify                   # smoke tests: VM, images, sandbox semantics, concurrency

# wire up your OpenCode Go + DeepSeek official keys
mkdir -p ~/.ai-secrets && chmod 700 ~/.ai-secrets
cp ~/ai-projects/ai-sandbox/secrets/ai-gateway.env.example \
   ~/.ai-secrets/ai-gateway.env
chmod 600 ~/.ai-secrets/ai-gateway.env
$EDITOR ~/.ai-secrets/ai-gateway.env
just seed-secrets

# OpenCode TUI sandbox
just new proj-alpha
just up proj-alpha            # then re-enter any day: just attach proj-alpha

# DeepSeek Harness web UI — another flavor on the SAME project dir
just up proj-alpha-dsh        # prints http://localhost:3080
```

The VM is named `ai-box` by default. Prefer your own name? Name it at
creation and keep passing it — `just vm-up my-box`, then `just build
my-box`, `just shell proj-alpha my-box` — or make it the standing
default: `cp .just.env.example .just.env` and set `VM_NAME=my-box`
(auto-loaded by every `just` command). A dedicated guest **user** (not
your macOS username) or different sizing: `cp .lima.env.example
.lima.env` and set e.g. `user.name=boxer` — applied at VM creation;
`just vm-rebuild` to change. Either way, every VM-touching command
takes the name as its trailing argument
([COMMANDS.md](docs/COMMANDS.md)).

Inside an OpenCode sandbox you land in `/workspace` (the project dir,
live-synced from the Mac) with `opencode` and every toolchain on PATH.
`docker` / `docker compose` work against the sandbox's private daemon.
The DSH flavor starts the DeepSeek Harness web UI inside the same kind of
sandbox; open the printed localhost URL in your Mac browser. The VM stays
agent-less in both cases.

## Daily use

| Task | Command |
| --- | --- |
| See what projects and sandboxes exist | `just ls` (tree: projects, used flavors, live states) |
| Open a project for work (stays running) | `just up proj-alpha` — opencode / `just up proj-alpha-dsh` — deepseek |
| Get back into it — same container, any day | `just attach proj-alpha` (or `proj-alpha-dsh`) |
| One-off task in a closed project | `just shell proj-alpha` (refused while that flavor is up) |
| Print a sandbox's log (dsh URL/token) | `just logs proj-alpha-dsh` (add `-f` to follow live) |
| Reach a sandbox port on the Mac | opt-in window (`SANDBOX_PORTS=1` in `.sandbox.env`) or `just expose proj-alpha 3000` |
| See what's listening / release ports | `just expose proj-alpha` / `just unexpose proj-alpha` / `just unexpose --all` |
| Print a DSH URL | `just dsh-url proj-alpha` |
| Keepalive ping for the OpenCode Go plan | `just activate` |
| New project | `just new <name>` |
| Refresh agent CLIs | `just bump-agents && just build` |
| Update gateway keys | `just seed-secrets` |
| Apply gateway route edits | `just gateway-reload` |
| Health check | `just verify` / `just status` |
| Reset one flavor | `just clean <name>[-dsh|-clean]` (keep data) / `just purge <name>[-dsh|-clean]` (wipe) |
| Rebuild the VM | `just vm-rebuild` |
| Custom or second VM name | append it: `just up proj-alpha my-box` — or set `VM_NAME` once in `.just.env` |

The default working mode for real projects: `just up` once — the
sandbox is a dev machine that stays powered on — `tmux` inside so the
TUI survives detach, and `just attach` whenever you return, even days
later. `just shell` is the one-off verb for closed projects: quick
task, exit, container gone. Volumes — including OpenCode's session
history — persist either way.

Every verb — arguments, defaults, prompts, and which to pick when two
look similar — is documented in the command reference:
[COMMANDS.md](docs/COMMANDS.md).

## GUI ergonomics

- **DeepSeek Harness is a web app** — it runs inside the sandbox, and its
  port is published to macOS `localhost`. This is a first-class mode, not
  a workaround.
- **OpenCode is a TUI** — run it natively over ssh + tmux. That is its
  intended form.
- **Web UIs just work** — anything the agent serves on a port (vite,
  storybook, API docs) reaches your Mac's localhost via the opt-in window
  (`SANDBOX_PORTS=1` + `PORT_BASE`/`PORT_BASE_END` in the project's
  `.sandbox.env`, merged by `just up`) or `just expose <name> <port>`.
  See docs/RUNBOOK.md → "Two network layers".
- **IDE / agent-GUI** — VS Code or Cursor on the Mac **attaches into the
  running sandbox container** (Dev Containers → Attach to Running
  Container, over a docker context pointing at the VM). IDE extensions
  then run inside the sandbox and reuse the baked CLIs + gateway wiring.
  Provider *web* GUIs that run agents in their clouds bypass your sandbox
  and keys entirely.
  Full setup: [BOOTSTRAP.md](docs/BOOTSTRAP.md) §IDEs & agent GUIs.

## Repo map

```
vm/ai-box.yaml           the Lima VM manifest (VM pins: sysbox, caddy, registry)
images/Dockerfile        layered flavors: base→node-core→toolchains→{whiteboard,opencode,deepseek}
images/docker-bake.hcl   every image pin, one file
images/rootfs/           baked OpenCode config, DSH web profile, dsh-web launcher
sandbox/compose.sandbox.yaml per-project sandbox template (one file, every project & flavor)
sandbox/compose.ports.yaml   opt-in dev-server window (SANDBOX_PORTS=1 in .sandbox.env)
sandbox/compose.dsh.yaml     dsh override: DSH UI port + dsh-home volume
sandbox/compose.dsh.ports.yaml  opt-in dsh dev window (same SANDBOX_PORTS switch)
sandbox/*.env.example        templates: .sandbox.env (knobs), .ai.env (container env)
gateway/Caddyfile        protocol-blind credential gateway (OpenCode Go + DeepSeek)
scripts/bump.sh          refresh version pins from upstream
scripts/verify.sh        smoke tests: VM, images, sandbox semantics, three-flavor concurrency
scripts/seed-secrets.sh  install gateway keys from the Mac
scripts/go-keepalive.sh  the OpenCode Go keepalive curl (run by `just activate`)
docs/                    ARCHITECTURE / BOOTSTRAP / COMMANDS / UPDATES / SECURITY / RUNBOOK / AGENT-CONFIG / FAQ / ARCHIVE / OPENAI-PLUS
```

Docs: [ARCHITECTURE](docs/ARCHITECTURE.md) · [BOOTSTRAP](docs/BOOTSTRAP.md)
· [COMMANDS](docs/COMMANDS.md) · [UPDATES](docs/UPDATES.md) ·
[SECURITY](docs/SECURITY.md) · [RUNBOOK](docs/RUNBOOK.md) ·
[AGENT-CONFIG](docs/AGENT-CONFIG.md) · [FAQ](docs/FAQ.md) ·
[ARCHIVE](docs/ARCHIVE.md) · [OPENAI-PLUS](docs/OPENAI-PLUS.md)
