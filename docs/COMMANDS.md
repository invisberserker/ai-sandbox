# The `just` command reference

`just --list` prints the menu (each recipe's one-line doc comment);
this page is the manual — arguments, defaults, prompts, and which verb
to pick when two look similar. Every command runs **on the Mac**; each
wraps the two-hop path (limactl → docker inside the VM) so you never
type the incantation. `brew install just` if you haven't.

Every command that touches the VM takes its name as the trailing
argument — `just vm-up my-box`, `just build my-box`, `just shell
proj-alpha my-box`. Omit it and the name falls back to `$VM_NAME`, then
to `ai-box`. `$VM_NAME` can come from your shell (`VM_NAME=my-box just …`
beats the file) or — no export needed — from `.just.env` at the repo
root, which `just` auto-loads: uncomment `VM_NAME=…` there (template:
`.just.env.example`) and every command in this directory targets your
box. Build-time customization (guest username, `cpus`/`memory`/`disk`)
lives in `.lima.env` instead — each `path=value` line becomes a
`limactl --set` at VM creation (template: `.lima.env.example`); it is
addressing vs. building: two files, two jobs. The repo stays at
`~/ai-projects/ai-sandbox` either way. The private recipes
(`compose`, `running_containers`, `sweep_relays`, `_bake`) are the
internal plumbing behind the verbs below — not part of the API.

## VM lifecycle

| Command | What it does |
| --- | --- |
| `just vm-up [vm]` | Create + provision the VM from `vm/ai-box.yaml` (first run ~5 min: seven provisioning steps, gated by readiness probes). Safe to re-run: on an existing VM it starts it (no-op if running) instead of re-creating. Also applies + verifies the VM user's docker group. `.lima.env` (guest user, sizing) applies at creation. |
| `just vm-stop [vm]` | Stop the VM. Nothing is deleted. |
| `just vm-shell [vm]` | Interactive shell ON the VM — logs, docker, the mirror. Don't run agents there ([SECURITY.md](SECURITY.md)). |
| `just status [vm]` | One screen of health: lima state, kernel holds, docker/sysbox versions, local images. Read-only. |
| `just vm-rebuild [vm]` | Delete + recreate the VM, then rebuild the images. **No prompt** — it acts immediately. Survivors: source + `~/.ai-secrets` on the Mac; casualties: outer image cache, per-flavor volumes, mirror cache. |
| `just nuke [vm]` | Delete the VM entirely — prompts y/N. Same survivors as `vm-rebuild`; recreate with `just vm-up <vm> && just build <vm>` (the recipe prints it with your name filled in). |

## Images

| Command | What it does |
| --- | --- |
| `just build [vm]` | Build `ai-base` + the three flavor images (`ai-whiteboard`, `ai-opencode`, `ai-deepseek`) inside the VM. Stamps two tags per image: `:latest` (what sandboxes consume) and `:YYYYMMDD`; a project pins a known-good day with `IMAGE_TAG=YYYYMMDD` in its `.sandbox.env`. |
| `just bump-agents` | Refresh the two agent CLI pins (`OPENCODE_VERSION`, `DSH_VERSION`) from npm — the weekly habit. Follow with `just build`. |
| `just bump-all` | Refresh every image pin (node patches within the pinned major, typescript, fnm, uv, go, rust, cargo-binstall, base digest) — the monthly-ish habit. Follow with `just build && just verify`. |
| `just verify [vm]` | Smoke tests inside the VM: services, images, toolchains, gateway routes, one full sysbox boot, and all three flavors of one dir running concurrently. Exits nonzero if anything fails; run it whenever something feels off. |

## Projects

Every project verb requires a one-time `just new <name>` (it creates the
project's flavor-agnostic `.sandbox.env`); the commands fail with a hint
if it's missing.

**Flavors are per-invocation.** Every project verb takes the project
name with an optional flavor suffix: `<name>` runs the OpenCode TUI
sandbox, `<name>-dsh` the DeepSeek Harness one, `<name>-clean` the
agent-free whiteboard one. All mount the same `~/ai-projects/<name>` dir
as **separate compose projects** — disjoint containers, volumes and
networks — so they can run at the same time over one source tree (the dsh
one also publishes the DSH UI and persists `dsh-home`). A project name
must never itself end in `-dsh` or `-clean`; `new` rejects both.

| Command | What it does |
| --- | --- |
| `just ls [vm]` | One-screen tree of `~/ai-projects`: every dir (scaffolded or not, repo marked), the flavors that have EVER been used — decided by their docker volumes, which both `shell` and `up` create and only `purge` removes — and each flavor's live state: `● up` (hint: attach), `◐ shell` (a live one-off session), `○ stopped` (volumes kept; hint: up). `expose` relays show beside their flavor (`relays :3000`), and the `-dsh` line carries its `DSH_PORT` URL. Read-only, one VM roundtrip; with the VM down it degrades to the project list plus a warning. |
| `just new <name>` | Scaffold `~/ai-projects/<name>` with a flavor-agnostic `.sandbox.env` — one file, safe on an existing repo checkout. `<name>`: starts with a letter or digit, lowercase letters/digits/`-`/`_`, never a reserved flavor suffix. Pin a known-good image tag with `IMAGE_TAG=YYYYMMDD` in the file. |
| `just shell <name>[-dsh|-clean] [vm]` | One-off session: fresh container, **removed at exit** — fresh OS each run, volumes persist. For short, well-defined tasks in a CLOSED project. **Refused while ANY container of that flavor is running**: an up'd sandbox → use `attach`; a live/forgotten `shell` session → it holds the inner docker store, and the message names the container and how to remove it. |
| `just up <name>[-dsh|-clean] [vm]` | Open the project for work: the sandbox runs in the background and **keeps running** — live context (agent TUI, tmux, dev servers) accumulates across days and project switches. Also required for the ports window and IDE attach. Refused while a live `shell` session of that flavor holds the store. The `-dsh` form prints the DSH URL plus the first-auth hint. |
| `just attach <name>[-dsh|-clean] [vm]` | Your everyday entry once the flavor is `up`: bash inside the running sandbox. Exit the exec without stopping anything. |
| `just logs <name>[-dsh|-clean] [vm] [-f]` | Print the running sandbox's startup/supervisor log — last 100 lines, then exit, like `docker logs`/`kubectl logs`. The dsh launcher prints its URL/token here on every boot — including the first-auth `/deepseek?token=…` link. `-f`/`--follow` streams live instead (the flag and the VM name work in either order); Ctrl+C then ends the follow quietly (the stream's designed exit, not a failure). Refused without an up'd container: a live `shell` session's log is the raw TUI escape stream, which floods the terminal ([FAQ](FAQ.md) → "docker logs"). |
| `just clean <name>[-dsh|-clean] [vm]` | `compose down` for that flavor: containers + network + its expose relays; volumes kept. |
| `just purge <name>[-dsh|-clean] [vm]` | Prompts y/N, then wipes THAT FLAVOR's volumes (dsh: including dsh-home). Source on the Mac untouched. Relays swept first. |
| `just expose <name>[-dsh|-clean] [HOST[:CONTAINER]] [vm]` | Forward one sandbox port to macOS localhost, docker `-p` / `kubectl port-forward` order: LEFT = the port you open on the Mac, RIGHT = the port the app listens on inside; a single port maps the same number both sides. No spec = discovery: listeners + relay status. The relay targets the compose service name over the project's own network, so sandbox recreates are absorbed via DNS. |
| `just unexpose <name>[-dsh|-clean] [HOST[:CONTAINER]] [vm]` | Release relays — three widening scopes: one claim (`unexpose test 3001`), that flavor's relays (`unexpose test`), every relay on the VM (`unexpose --all`, the "start clean" form — no prompt, relays carry no data). `--all` takes the project-name slot, so the VM follows it: `unexpose --all my-box` (not `unexpose my-box --all`). |
| `just dsh-url <name>[-dsh|-clean]` | Print the plain DSH macOS URL (`DSH_PORT` from the project's `.sandbox.env`, default 3080). A project-level question: the bare, `-dsh` and `-clean` names all resolve to the same dir, so whichever flavor you named, the answer is the project's DSH UI. No `[vm]` — it only reads the project dir on the Mac. Errors on an unscaffolded name instead of inventing a URL; the first-auth token lives in the logs, not here. |
| `just activate [vm]` | The unattended OpenCode Go keepalive — the idle-morning ritual as one command. Scaffolds the recipe-owned burner project `go-keepalive`, runs `scripts/go-keepalive.sh` in a one-off sandbox (`shell` semantics, TTY-less, cron/launchd-safe): one gateway-routed curl asking for a dad joke — a 200 reply opens/refreshes the plan's **5-hour rolling window**; anything else fails loudly with the [RUNBOOK](RUNBOOK.md) decode. Then: `purge` minus the y/N (`down -v` — the project is seconds old) and `rm -rf ~/ai-projects/go-keepalive`. No prompts, no residue; a run killed midway is healed by the next. Never use `go-keepalive` as a real project name. |

DSH notes: each concurrently running DSH project needs its own `DSH_PORT`
in its `.sandbox.env` (3080, 3081, 3082 …). The DSH UI port is always
published; the dev-server window is opt-in with `SANDBOX_PORTS=1` and then
needs its own `DSH_PORT_BASE` window. First boot flow: `just up <p>-dsh`,
then `just logs <p>-dsh` for the `/deepseek?token=…` link — open it once
in a macOS browser and you're authenticated.

## Secrets & gateway

| Command | What it does |
| --- | --- |
| `just seed-secrets [vm]` | Copy `~/.ai-secrets/ai-gateway.env` into the VM (`/etc/ai-gateway/secrets.env`, root-only) and restart the gateway. Run after editing **keys**. |
| `just gateway-reload [vm]` | Copy the repo's `gateway/Caddyfile` to the VM, `caddy validate` it, restart the gateway. Run after editing **routes**. |

Keys vs routes: `seed-secrets` moves key *values*; `gateway-reload`
moves route *config*. Editing either file on the Mac does nothing on
the VM until you run the matching command.

## More than one VM

The default VM is named `ai-box`, and every verb above targets it
silently. A second instance — say, a scratch VM for trying a sysbox or
Ubuntu bump — is just a name:

```bash
just vm-up scratch-box
just build scratch-box
just new tryout && just shell tryout scratch-box
just nuke scratch-box          # deletes ONLY this VM
```

Each VM keeps its own images, mirror and inner volumes, but both mount
the same `~/ai-projects` source on the Mac, so a project can run in
either (or both) with independent inner state. Two caveats: ports —
every VM forwards its loopback to the same macOS `127.0.0.1`, so DSH
projects running in parallel VMs need distinct `DSH_PORT`s (and distinct
window ranges when `SANDBOX_PORTS=1`) — and RAM: one VM is the intended
shape; N VMs fragment memory and duplicate caches
([ARCHITECTURE.md](ARCHITECTURE.md) → "Why this shape"). For a
name you use permanently, put `VM_NAME=my-box` in the repo-root
`.just.env` (auto-loaded, gitignored; template: `.just.env.example`) —
no trailing argument, no export.

## Picking the right verb

- **`shell` vs `up` + `attach`** — the two working modes. **`up` +
  `attach` is the default for project work**: `up` leaves the sandbox
  running like a dev machine that stays powered on, so live context —
  the running TUI, tmux layout, dev servers — accumulates; detach
  today, `attach` two days later, and it's all where you left it — or
  further along: the agent keeps WORKING while you're away (kick off a
  long task, detach, come back to progress, not a checkpoint).
  Several projects can stay open at once (idle cost is small; the VM
  sizing assumes 2-4 concurrent sandboxes). **`shell` is the
  deliberate one-off** (`compose run --rm`): fresh container, removed
  at exit — right for a short, well-defined task in a CLOSED project;
  past conversations still resume from the volume (see below), so even
  one-offs start warm. ⚠ Never `shell` into a flavor that's already
  `up` — even for a one-second look-inside: the one-off container mounts
  the same `inner-docker-data` volume, and two inner daemons on one
  docker store corrupt it. The `shell` recipe refuses and points at
  `attach` — and it also refuses when a live/forgotten `shell` session
  is still holding the store (same corruption, name the container to
  remove). Raw docker won't stop you, so don't bypass the guard. A
  DIFFERENT flavor is fine: its store is disjoint.

  Either way the volumes persist: source, build caches, inner docker
  images, OpenCode config/auth — and OpenCode's session history
  (`~/.local/share/opencode`, on the `home-local` volume), so a past
  conversation can be resumed from the TUI even after `clean`. What
  only `up` preserves is the live process tree.
- **`activate` vs a manual `shell`** — `activate` IS a `shell` run,
  scripted: same fresh-container `compose run --rm`, but the session is
  the repo's one-liner curl (`scripts/go-keepalive.sh`) instead of a
  keyboard, the project is the recipe-owned `go-keepalive` burner, and
  the exit sweeps it (`down -v` + `rm -rf`). It exists because the
  OpenCode Go plan's 5-hour rolling window opens on ANY request: one
  cheap dad-joke ping on an idle morning — no typing, no residue.
- **`clean` vs `purge` vs `vm-rebuild`/`nuke`** — the ephemerality
  ladder ([ARCHITECTURE.md](ARCHITECTURE.md) → "Ephemerality ladder"):
  `clean` drops the container OS, `purge` also drops that flavor's
  volumes, `vm-rebuild`/`nuke` drop the whole VM — every flavor's
  volumes with it. Suffix-scoped: `clean proj-dsh` touches only the dsh
  sandbox of that dir; `clean proj-clean` only the whiteboard one.
- **ports window vs `just expose`** — the two ways to reach a sandbox
  port from the Mac, mirroring compose `ports:` vs `kubectl
  port-forward`: a **declared window** in `.sandbox.env`
  (`SANDBOX_PORTS=1` + `PORT_BASE..`; default off; for projects with
  known, contiguous dev ports; identity mapping; `just up` only) vs an
  **imperative relay** (`just expose`; any port; works on live `shell`
  sessions too; natural claim, loud conflict). Window claims release
  with `clean`; relays with `unexpose` — or `unexpose --all` for a
  fleet reset.
- **`bump-agents` vs `bump-all`** — weekly agent-CLI pins vs monthly
  everything. Both need a following `just build`, and running sandboxes
  keep their old image until restarted.

Prereqs for all of it: VM up, images built, keys seeded —
[BOOTSTRAP.md](BOOTSTRAP.md) if you're starting from zero.
