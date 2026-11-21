# Bootstrap

From bare Mac to first sandbox session. Commands run **on the Mac**
unless a line says otherwise. Agents — including the DSH web UI — run
inside sandboxes in the VM.

## 0. Prerequisites

- Apple Silicon Mac, macOS 13+ (Virtualization.framework requirement for
  `vmType: vz`), ~25 GB free disk.
- [Homebrew](https://brew.sh), then:

  ```bash
  brew install lima just
  limactl --version   # needs lima >= 2.3: the VM manifest uses
                      # networkOpts.hostLoopback and stable vz/virtiofs/
                      # mountPoint features
  ```

- RAM sanity: see the sizing table in `vm/ai-box.yaml` (defaults assume a
  32 GB Mac; override per-start with `limactl start --set '.memory=...'`).

## 1. Place the repo

The whole stack assumes the repo lives at `~/ai-projects/ai-sandbox`
(provisioning references it through the VM mount):

```bash
mkdir -p ~/ai-projects
cp -R /path/to/ai-sandbox ~/ai-projects/ai-sandbox
cd ~/ai-projects/ai-sandbox
```

## 2. Create the VM

```bash
just vm-up
```

This runs `limactl start --name=ai-box vm/ai-box.yaml`: downloads the
Ubuntu 24.04 arm64 cloud image, boots it under vz, and runs the six
provisioning steps (packages → kernel pin → docker-ce → sysbox → registry
mirror → credential gateway). Lima blocks until the probes pass — a failed
probe is a loud failure at boot, not a mystery later. First run: ~5 min.

Want the VM under a different name? `just vm-up my-box` — then keep
passing it (`just build my-box`, `just shell proj-a my-box`), or make
it standing: `cp .just.env.example .just.env` and set `VM_NAME=my-box`
there (auto-loaded by every `just` command, gitignored). A dedicated
guest **user** (not your macOS username) or custom sizing:
`cp .lima.env.example .lima.env` — applied at VM creation
(`just vm-rebuild` to change). Every VM-touching command works the
same way.

Verify the appliance:

```bash
just vm-shell          # poke around; exit with `exit`
docker info | grep -A3 Runtimes   # inside the VM: sysbox-runc present
```

## 3. Build the images

```bash
just build             # base + the three flavors: whiteboard, opencode, deepseek
just verify            # full smoke test — everything below should PASS
```

`verify` checks the VM services, both agent CLIs (OpenCode + dsh), the
shared toolchains (node/tsc, rust, go, python-via-uv), the gateway routes,
and boots one real sysbox sandbox to prove the inner dockerd + isolation
semantics.

## 4. Secrets (do once)

The gateway runs with placeholder keys until you do this; agent requests to
OpenCode Go / DeepSeek will fail with 401s until then (loud, by design).

```bash
mkdir -p ~/.ai-secrets && chmod 700 ~/.ai-secrets
cp ~/ai-projects/ai-sandbox/secrets/ai-gateway.env.example \
   ~/.ai-secrets/ai-gateway.env
chmod 600 ~/.ai-secrets/ai-gateway.env
$EDITOR ~/.ai-secrets/ai-gateway.env   # OpenCode Go + DeepSeek keys
just seed-secrets
```

For gateway-routed providers, the keys now exist in exactly one file on
the Mac — outside `~/ai-projects`, shared into the VM **read-only**
(`/mnt/secrets`), so even a compromised VM cannot tamper with your only
copy — plus one root-only file on the VM. Sandboxes never see either.
Direct BYOK keys (OpenCode third-party providers) are the explicit
exception.

After editing gateway *routes* (not keys), run `just gateway-reload` to
copy the repo Caddyfile to the VM, validate it, and restart the gateway.

## 5. First sandbox

### OpenCode TUI

First touch — a one-off session to sanity-check the machinery:

```bash
cd ~/ai-projects/ai-sandbox
just new proj-alpha ai-opencode
just shell proj-alpha
```

You land in `/workspace` (= `~/ai-projects/proj-alpha` on the Mac,
live-synced). Sanity checks inside:

```bash
opencode --version       # your flavor's agent CLI
cargo --version && go version && uv --version && tsc --version
                         # every flavor carries ALL toolchains
docker run --rm hello-world   # PRIVATE inner daemon works
cat /proc/self/uid_map   # 0 → 165536-ish: root inside, unprivileged outside
```

**How you'll actually work: two modes.** Ephemeral refers to the
container OS, not to your project's memory. For real work, open the
project and attach to it — the sandbox becomes a dev machine that
stays powered on, so the live context (running TUI, tmux, dev servers)
accumulates across days and project switches:

```bash
just up proj-alpha        # project "open": sandbox runs in the background
just attach proj-alpha   # tmux new -A -s agent; opencode; Ctrl-b d; exit
just attach proj-alpha   # two days later — tmux attach -t agent: still there
```

Start the TUI inside either mode with `opencode` (provider wiring:
[AGENT-CONFIG.md](AGENT-CONFIG.md)); the baked `attach` alias
(tmux create-or-attach) is the habit that makes the TUI survive
detach. `Ctrl-b d` leaves it running — which is also what lets an
agent keep WORKING while you're away: kick off a long task, detach,
switch projects, and come back to progress, not a checkpoint.

`just clean proj-alpha` closes the project when you want it off: the
live processes die, but the volumes persist — source caches, inner
images, OpenCode config/auth, and its session history under
`~/.local/share/opencode` — so a past conversation can be resumed
from the TUI instead of re-primed from scratch. `just shell` remains
the one-off verb: a short, well-defined task in a closed project — a
quick edit, an inspection, asking an agent for a dad joke — fresh
container in, gone at exit. (Never `shell` into a project that's
already `up` — see [COMMANDS.md](COMMANDS.md).)

### DeepSeek Harness web UI

```bash
just new dsh-proj ai-deepseek
just dsh-up dsh-proj     # prints http://localhost:3080
```

Open the URL in a macOS browser. The UI runs inside the sysbox sandbox;
the VM stays agent-less. See [AGENT-CONFIG.md](AGENT-CONFIG.md) for the
DSH model wiring and per-project `DSH_PORT` planning.

## 6. Wiring a real repo

`just new` writes exactly one file — `<project>/.sandbox.env` — so it is
safe to run inside an existing checkout; it never touches repo content:

```bash
git clone <url> ~/ai-projects/my-app
just new my-app                # creates ~/ai-projects/my-app/.sandbox.env
just shell my-app
```

The knobs file is deliberately **not** `.env`. Your repo probably has its
own `.env` (the standard dotenv convention) — the sandbox never reads
it, and your app never reads the sandbox's. Three files, three different
consumers, no merging:

| File | Who reads it | Enters the sandbox? |
| --- | --- | --- |
| `.env` | your application only | only if your app loads it |
| `.sandbox.env` | docker compose (via the Justfile's `--env-file`) | not as a file — compose only substitutes its `${VAR}` placeholders when rendering the config; a value enters only where the compose files interpolate it into `environment:` (e.g. `DSH_PORT` in the dsh override) |
| `.ai.env` | compose `env_file` block | yes — every line is injected into the container at start |

Per-machine knobs usually stay out of the repo: add `.sandbox.env` to
the project's `.gitignore` unless you want to share the settings.

When you do want a `.ai.env` — entrypoint knobs, tool env, proxy vars,
or the dummy key for an extra gateway route — copy
`sandbox/ai.env.example`; it includes the full recipe for putting a
third-party provider behind the gateway.

Git by default: the sandbox commits, you push from the Mac. For
projects you offload completely — the agent commits AND pushes with
its own dedicated key, no per-diff review — the recipe is in the same
template and [SECURITY.md](SECURITY.md) → "Git auth" (one `.ai.env`
line; per-repo deploy key recommended over an account key).

Or clone straight into the tree: `git clone <url> ~/ai-projects/my-app`,
then `just new my-app` as above.

## 7. Ports to the Mac (web UIs, dev servers) — when you need them

Uncomment the `ports:` block in `sandbox/compose.sandbox.yaml` (or keep a
per-project override), set `PORT_BASE` in the project `.sandbox.env`, and
run the sandbox in long mode:

```bash
just up proj-alpha      # instead of `shell`
just attach proj-alpha
open "http://localhost:$(grep '^PORT_BASE=' ~/ai-projects/proj-alpha/.sandbox.env | cut -d= -f2)"
```

Read [RUNBOOK.md](RUNBOOK.md#two-network-layers) before inventing port
schemes — two layers of forwarding are involved.

## IDEs & agent GUIs from the Mac

The DSH flavor is already a web GUI running inside the sandbox; open its
localhost URL directly. For everything else, the GUI that fits is
**VS Code (or Cursor) on the Mac, attached INTO the sandbox container** —
window and chrome on macOS, agent + code + credentials contract inside the
sandbox. Provider web/desktop GUIs that run the agent in the provider's
cloud still bypass the sandbox + gateway; skip those.

The container running the agent **is** the dev environment: it is
reachable directly from macOS through attach/ports, with no extra macOS
VS Code dev container.

One-time setup:

```bash
# make lima's generated ssh config visible (docker-over-ssh needs it too)
echo 'Include ~/.lima/*/ssh.config' >> ~/.ssh/config

# point your Mac's docker CLI at the VM daemon via ssh
docker context create ai-box --docker "host=ssh://lima-ai-box"
```

Per project (sandbox must be RUNNING for attach — use `up`, or `dsh-up`
for a DSH project):

```bash
just up proj-alpha          # sandbox runs in the background
# VS Code: Dev Containers → "Attach to Running Container..." → select
# ai-box context → the proj-alpha agent container.
```

Notes:

- Pick the `ai-box` docker context in VS Code's Docker view if attach
  lists nothing.
- VS Code server + extensions persist on the `vscode-server` volume, so
  re-attaching after container resets is quick.
- Terminal purists: `just attach proj-alpha` gives a plain shell into the
  same running sandbox (tmux lives there too).
- **Remote-SSH into `lima-ai-box` directly** is fine for VM-level poking
  (logs, docker, mirror) — but don't run agents there: outside the
  sandbox, on the VM's global OS, is exactly where agents must not be.
- Cursor works the same way (Remote-SSH / container attach are inherited
  from its VS Code base).

## Day-2 short list

- Weekly: `just bump-agents && just build && just verify`
- Something's off: `just verify`, then [RUNBOOK.md](RUNBOOK.md)
- Every verb on one page: [COMMANDS.md](COMMANDS.md)
- Reset a project: `just clean <p>` / `just purge <p>`
- Reset a DSH project: `just dsh-stop <p>` / `just dsh-purge <p>`
- Nuke & pave the VM: `just vm-rebuild`
- Change VM size: set `cpus`/`memory`/`disk` in `.lima.env`, then `just vm-rebuild`
