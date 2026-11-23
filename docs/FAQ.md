# FAQ — design questions asked & answered

The reasoning behind choices that aren't obvious from the manifests
alone. Each entry points at the deeper write-up where one exists.

## Why do I see the same image pulled more than once? (the mirror)

Docker inside this VM behaves exactly like docker on your Mac — and
that's the point. An image cache is **per-daemon, never per-machine**:
it lives in each daemon's own `/var/lib/docker`. On macOS you run ONE
daemon (inside Docker Desktop's/OrbStack's hidden utility VM), so all
projects share one store and `postgres:16` downloads once, ever.

This stack deliberately runs **one daemon per sandbox** (the sysbox
isolation: private docker, private store, safe `docker compose up`).
Concurrent daemons cannot share one image store without corrupting each
other, so each inner daemon gets its own `/var/lib/docker` on a
per-project volume — and the same public image is downloaded and stored
once per project that uses it. The outer side never duplicates:
ai-opencode/ai-deepseek images are built once and shared copy-on-write by
all sandboxes; only inner-daemon pulls (test services) repeat.

The pull-through mirror deduplicates the **network**, not the disk:
every daemon pulls through the VM's registry-mirror cache (the
`REGISTRY_IMAGE` pin in `vm/ai-box.yaml`; outer via `daemon.json`, inner
via the entrypoint's `--registry-mirror`), so an image is fetched from
Docker Hub once and served at disk speed to every other project. Disk
duplication per project remains by design — `just purge <dead-project>`
reclaims it.

Deep dive: [ARCHITECTURE.md](ARCHITECTURE.md) §"Registry mirror".

## Can I use the providers' agent GUIs?

Providers ship two kinds of GUI, and they behave very differently here:

- **Web/desktop GUIs** that run the agent in the provider's cloud — your
  code leaves the Mac and the sandbox + gateway + isolation play no role.
  Out of scope by design, and no desktop-environment VM would fix that.
  (DSH is the exception: its web UI runs *inside* the sandbox.)
- **IDE extensions** that drive a local agent/workspace fit perfectly:
  **VS Code/Cursor on the Mac, attached INTO the running sandbox
  container** (Dev Containers → Attach to Running Container, over a
  docker context pointing at the VM). Attach, not Remote-SSH: Remote-SSH
  lands on the VM's OS, where agents must not run. The DSH flavor is
  already a web UI inside the sandbox; just open its localhost URL.

Setup walkthrough: [BOOTSTRAP.md](BOOTSTRAP.md) §"IDEs & agent GUIs".

## `just shell` or `just up` + `just attach` — which is the everyday verb?

Both are correct — for different jobs. The mistake is using `shell` for
work that spans days. "Ephemeral" refers to the container OS, not to
your project's memory, and the split follows what carries the context:

- **`up` + `attach` is the working mode for a project.** `up` leaves
  the sandbox running like a dev machine that stays powered on, so the
  live context — running OpenCode TUI, tmux layout, dev servers,
  background agent work — accumulates. Detach today, `attach` two days
  later, and everything is where you left it — or further along: an
  agent mid-task keeps working while you're detached. There is no
  forced "decisive end" to a session, and several projects can stay
  open at once (idle cost is small; the VM sizing assumes 2-4
  concurrent sandboxes).
- **`shell` is the one-off verb.** Fresh container, removed at exit —
  right for a short, well-defined task in a CLOSED project: a quick
  edit, an inspection, asking an agent for a dad joke. Never while that
  flavor is already `up` — the one-off container would put a second
  inner daemon on the project's docker store and corrupt it. The
  `shell` recipe refuses and points at `just attach`; the same refusal
  covers a forgotten earlier `shell` session still holding the store.
  The rule applies per flavor (a `shell test-dsh` next to an up'd
  `test` is fine — disjoint stores).

What persists across resets either way (volumes): source, build caches,
inner docker images, OpenCode config/auth — and OpenCode's session
history (`~/.local/share/opencode`, on the `home-local` volume), so even
after `just clean` a past conversation can be resumed from the TUI
instead of re-primed from scratch. What only `up` preserves: the live
process tree.

Full command reference: [COMMANDS.md](COMMANDS.md).

## Why did `docker logs` on my `just shell` session flood the terminal and eat Ctrl+C?

The container's **main pty is your TUI**. `just shell` (compose `run`)
attaches the interactive session to the container's main pty, and for
`tty: true` containers the log store *is* that pty's output — every
Bubble Tea frame the OpenCode TUI ever drew, including terminal
mode-setters (alternate screen, mouse tracking, the kitty keyboard
protocol push). `docker logs` replays it all into your terminal, which
EXECUTES those sequences: the flood is the frames themselves (unbounded
while a model streams), and the kitty push re-encodes your keystrokes —
Ctrl+C becomes a `CSI …;5u` report, never the 0x03 byte that produces
SIGINT, so the session looks hung and un-interruptable. Recovery from a
second window: `reset` (or `stty sane`) on the wedged tty.

`up`-mode containers log only the quiet supervisor stream (`[sandbox-init]`
lines) — your TUI lives in tmux/`exec` ptys, which docker never logs.
That's why `just logs` is guarded: it refuses to replay a live
shell-mode session and tells you so. Raw `docker logs` bypasses the
guard — now you know why not to.

## How do I reach a port inside a sandbox from the Mac?

Two layers, two gaps. Lima auto-forwards anything bound **in the VM** to
macOS localhost, same number — that layer is zero-config. But a sandbox
is a sysbox container with its **own network namespace**: dev servers
(and inner-daemon `-p` publishes) bind one layer deeper, invisible to
lima. Two deliberate ways to bridge it, mirroring the ecosystems' own
split:

- **Declarative window** (compose `ports:` style): `SANDBOX_PORTS=1` +
  `PORT_BASE`/`PORT_BASE_END` in the project's `.sandbox.env`, covering
  your app's contiguous dev ports. Identity mapping — sandbox port N
  appears on Mac localhost:N — published on every `just up`. The `-dsh`
  flavor gets its own window (`DSH_PORT_BASE`), so both flavors of one
  dir coexist.
- **Imperative relay** (`kubectl port-forward` style): `just expose
  <name> [HOST:CONTAINER]` — one port, any port, works on live `shell`
  sessions too; natural claim on the same number, loud conflict
  otherwise. `just expose <name>` (no spec) lists what the sandbox is
  listening on; `just unexpose` releases (`--all` = fleet reset).

Why not fully automatic ("bind and it's reachable")? Two hard reasons:
an eager wide publish breaks the moment two sandboxes run — which is
the whole point of multi-flavor projects — and letting a sandbox expose
*itself* would require giving the agent access to the outer docker
daemon, a direct violation of the isolation model (sandboxes only ever
talk to their private inner daemon). Even k8s's own answer for "reach
my pod from the laptop" is a per-port forward command; `just expose` is
that primitive.

Full walkthrough: [RUNBOOK.md](RUNBOOK.md) → "Two network layers".

## Why one gateway route for every OpenCode Go model?

Because the gateway is protocol-blind. OpenCode Go serves Chat
Completions, Responses, Anthropic Messages and Gemini under one origin
(`https://opencode.ai/inference/go/v1`). The TUI picks the API family per
model; Console translates server-side. Caddy only strips
`/opencode-go` and injects the real `Authorization` value, so one block
covers all models and protocols. Adding a model to the Go plan requires
zero gateway changes. Putting OpenAI/Anthropic/Gemini translation into
Caddy would duplicate OpenCode Console in the wrong layer.

## Why does the OpenCode flavor ride the same /deepseek route as dsh — no separate /opencode-deepseek?

Gateway routes are per-**upstream**, not per harness or per API family.
Both baked DeepSeek consumers — the dsh web profile and the OpenCode
flavor's endpoint-override of the catalog `deepseek` provider — send
OpenAI-shaped requests to `api.deepseek.com`. One route strips
`/deepseek`, forwards `/v1/...`, and swaps in the one real key for
whichever harness is talking. A second route would only duplicate the
upstream, the secret, and the surface to audit. Same principle as one
route covering every OpenCode Go model above.

## How would I use an OpenAI Plus subscription?

Two designs are recorded in [OPENAI-PLUS.md](OPENAI-PLUS.md): a scoped
shared `codex-identity` volume (simple, refresh token in those sandboxes)
and a refresh-aware token sidecar (preferred: real refresh token stays on
the VM, sandboxes get only short-lived access tokens). An API key through
the gateway remains the only no-real-credential-in-sandbox option.

## Why `just`, and what is it?

`just` is a command runner — a Justfile is named shell recipes with
parameters, defaults and one-line doc comments; `just --list` prints
the menu. No build system, no timestamps (the "Make for tasks, minus
Make" pitch).

It earns its place here because this stack's operations are two-hop
(macOS → VM → docker) and quoting-hostile: the raw form of "shell into
project X" is a long `limactl shell … bash -lc "cd … && docker compose
-f … --project-directory . …"` incantation with silent failure modes
(forget `--project-directory` and the wrong directory gets bind-mounted
as `/workspace`). The Justfile turns each load-bearing detail into a
named verb, gives the docs stable commands to reference, and makes
`just --list` the self-documenting API of the system — and the full
reference beyond those one-liners is [COMMANDS.md](COMMANDS.md). The
escape hatch is real though: every recipe is 2-5 lines of bash, so
porting to `scripts/*.sh` is mechanical if the dependency ever bothers
you.

## What is docker-bake.hcl?

Official Docker tooling: BuildKit's **bake**, invoked as
`docker buildx bake` (ships in the docker-buildx-plugin the VM already
installs), configured in HCL — the Terraform config format, which is
why it looks alien.

Role: it's to *building* images what docker-compose.yaml is to
*running* containers. Our Dockerfile is one shared chain of stages
(base → node-core → toolchains → flavors); without bake, building the
matrix means a separate `docker build` per target, each with a different
subset of ~10 `--build-arg`s and two `-t` tags, with version pins
living in shell code. docker-bake.hcl declares that matrix: `variable`
blocks are the version pins (the single source of truth `just
bump-agents` rewrites), `target` blocks say "build stage X with these
args, tag it thus", `group default` is what `just build` produces —
all in one parallel run that evaluates shared stages once.

Division of labor: Dockerfile = *how an image is assembled*;
docker-bake.hcl = *what gets built, with which versions, under which
tags*; Justfile = *when and where* (inside the VM, after a bump, with
the date tag).

## What does the entrypoint's `trap` stuff do? (PID 1 & SIGKILL)

The naive pattern — start dockerd in the background, readiness-poll, then
`exec "$@"` — leaves the inner dockerd with **no graceful shutdown path**:
on `docker stop`, tini forwards SIGTERM to its direct child only (the
exec'd session command — which dies instantly if it has no handler, or, if
it's the interactive bash of `just up`, IGNORES SIGTERM outright and hangs
the stop until docker's grace-period SIGKILL); the background daemon is a
grandchild nobody signals, and once the main process exits, Docker
hard-kills the cgroup. The daemon therefore always ends up SIGKILLed
mid-write. With a throwaway container that's harmless; with our
**persistent** `inner-docker-data` volume it's a corruption lottery for
the image store ("failed to read …json" on a future boot, cure = `just
purge`).

`docker-entrypoint.sh` instead keeps the shell alive as a supervisor:
the session command runs as a background *child* (no exec), and
`trap shutdown TERM INT` converts "container is stopping" into "run
cleanup", asking each child to leave in the way it actually honors:

- **Session: SIGHUP first, not TERM.** An interactive bash on the compose
  PTY (`tty: true` → `just up`) ignores SIGTERM — the old TERM-here
  design hung the stop until docker's grace-period SIGKILL. HUP is
  honored and propagates to the session's jobs (tmux, dev servers);
  if it lingers past a bounded ~5 s, escalate to SIGKILL, then reap
  (preserving the session's exit code on the plain-exit path).
- **dockerd: graceful TERM, bounded flush, then KILL.** A daemon honors
  SIGTERM, so it gets TERM and up to 10 s to flush metadata to the
  volume; SIGKILL only past that bound. Nothing to do under
  `SANDBOX_NO_DOCKERD`.

The same `shutdown` runs on plain session exit (`exit` typed in the
shell), so both exit paths converge; it's idempotent (traps reset
first, every kill guarded), so running twice is safe. The bounds
(~5 s + 10 s) sit far inside the compose `stop_grace_period: 60s`, so a
`docker stop` returns in seconds — no grace-period roulette. Signal
chain: docker → tini (reaps zombies) → supervisor → {session, dockerd}.
Details inline in `images/docker-entrypoint.sh`.

## Anything else worth knowing?

- Why one VM instead of N, why sysbox, why not Docker `sbx` / DinD /
  Multipass / Vagrant: [ARCHITECTURE.md](ARCHITECTURE.md) §"Tier 1" and
  the runtime comparison table.
- Why the kernel is pinned and how to move off it:
  [UPDATES.md](UPDATES.md) §"Moving off the pinned kernel".
- What a rogue agent can and cannot reach: [SECURITY.md](SECURITY.md)
  §"The four walls".
