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
(`compose`, `compose_dsh`, `_bake`) are the internal plumbing behind
the verbs below — not part of the API.

## VM lifecycle

| Command | What it does |
| --- | --- |
| `just vm-up [vm]` | Create + provision the VM from `vm/ai-box.yaml` (first run ~5 min: six provisioning steps, gated by readiness probes). Safe to re-run: on an existing VM it starts it (no-op if running) instead of re-creating. Also applies + verifies the VM user's docker group. `.lima.env` (guest user, sizing) applies at creation. |
| `just vm-stop [vm]` | Stop the VM. Nothing is deleted. |
| `just vm-shell [vm]` | Interactive shell ON the VM — logs, docker, the mirror. Don't run agents there ([SECURITY.md](SECURITY.md)). |
| `just status [vm]` | One screen of health: lima state, kernel holds, docker/sysbox versions, local images. Read-only. |
| `just vm-rebuild [vm]` | Delete + recreate the VM, then rebuild the images. **No prompt** — it acts immediately. Survivors: source + `~/.ai-secrets` on the Mac; casualties: outer image cache, per-project volumes, mirror cache. |
| `just nuke [vm]` | Delete the VM entirely — prompts y/N. Same survivors as `vm-rebuild`; recreate with `just vm-up <vm> && just build <vm>` (the recipe prints it with your name filled in). |

## Images

| Command | What it does |
| --- | --- |
| `just build [vm]` | Build `ai-base` + the three flavors (`ai-whiteboard`, `ai-opencode`, `ai-deepseek`) inside the VM. Stamps two tags per image: `:latest` (what sandboxes consume) and `:YYYYMMDD` (today, for pinning a known-good day in a project's `.sandbox.env`). |
| `just bump-agents` | Refresh the two agent CLI pins (`OPENCODE_VERSION`, `DSH_VERSION`) from npm — the weekly habit. Follow with `just build`. |
| `just bump-all` | Refresh every image pin (node patches within the pinned major, typescript, fnm, uv, go, rust, cargo-binstall, base digest) — the monthly-ish habit. Follow with `just build && just verify`. |
| `just verify [vm]` | Smoke tests inside the VM: services, images, toolchains, gateway routes, one full sysbox boot. Exits nonzero if anything fails; run it whenever something feels off. |

## Projects

Every project verb requires a one-time `just new <name>` (it creates the
project's `.sandbox.env`); the commands fail with a hint if it's
missing.

### OpenCode / whiteboard sandboxes

| Command | What it does |
| --- | --- |
| `just new <name> [image]` | Scaffold `~/ai-projects/<name>` with a `.sandbox.env` — image defaults to `ai-opencode:latest`; pass any tag (`just new dsh-proj ai-deepseek`, `just new proj-b ai-opencode:20261120`). Writes exactly ONE file, so it's safe on an existing repo checkout. `<name>` must be lowercase letters, digits, `-` or `_` (it becomes the compose project name). |
| `just shell <name> [vm]` | One-off session: creates a fresh container and **removes it at exit** — fresh OS each run, volumes persist. For short, well-defined tasks in a project that isn't currently `up` (a quick edit, an inspection, asking for a dad joke). |
| `just up <name> [vm]` | Open the project for work: the sandbox runs in the background and **keeps running** — live context (agent TUI, tmux, dev servers) accumulates across days and project switches. Also required for the `ports:` passthrough and IDE attach. |
| `just attach <name> [vm]` | Your everyday entry once the project is `up`: bash inside the running sandbox. Exit the exec without stopping anything. |
| `just clean <name> [vm]` | `compose down`: containers + network gone, volumes kept. |
| `just purge <name> [vm]` | Prompts y/N, then also wipes the project's VOLUMES (inner images, caches, agent state). Source on the Mac untouched. |

### DSH (DeepSeek Harness web sandboxes)

For DSH projects use the `dsh-*` twins instead of `clean`/`purge`, so
the DSH override (port + dsh-home volume) merges identically on the way
down. Each concurrently running DSH project needs its own `DSH_PORT`
in its `.sandbox.env`. To get a shell next to the running web UI:
`just attach <name>` — not `shell`, which would start a second
container without the DSH override.

| Command | What it does |
| --- | --- |
| `just dsh-up <name> [vm]` | Start the web sandbox in the background with the DSH override, then print its macOS URL (`http://localhost:<DSH_PORT>`). |
| `just dsh-url <name>` | Print the URL again (`DSH_PORT` from `.sandbox.env`, default 3080). No `[vm]` — it only reads the project's `.sandbox.env` on the Mac. |
| `just dsh-logs <name> [vm]` | Follow startup logs — where DSH prints its URL/token. |
| `just dsh-stop <name> [vm]` | `compose down` with the DSH override; volumes kept. |
| `just dsh-purge <name> [vm]` | Prompts y/N, then also wipes the dsh-home volume. |

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
projects running in parallel VMs need distinct `DSH_PORT`s — and RAM:
one VM is the intended shape; N VMs fragment memory and duplicate
caches ([ARCHITECTURE.md](ARCHITECTURE.md) → "Why this shape"). For a
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
  one-offs start warm. ⚠ Never `shell` into a project that's
  already `up` — even for a one-second look-inside: the one-off
  container mounts the same `inner-docker-data` volume, and two inner
  daemons on one docker store corrupt it — `attach` instead.

  Either way the volumes persist: source, build caches, inner docker
  images, OpenCode config/auth — and OpenCode's session history
  (`~/.local/share/opencode`, on the `home-local` volume), so a past
  conversation can be resumed from the TUI even after `clean`. What
  only `up` preserves is the live process tree.
- **`clean` vs `purge` vs `vm-rebuild`/`nuke`** — the ephemerality
  ladder ([ARCHITECTURE.md](ARCHITECTURE.md) → "Ephemerality ladder"):
  `clean` drops the container OS, `purge` also drops that project's
  volumes, `vm-rebuild`/`nuke` drop the whole VM — every project's
  volumes with it.
- **`bump-agents` vs `bump-all`** — weekly agent-CLI pins vs monthly
  everything. Both need a following `just build`, and running sandboxes
  keep their old image until restarted.

Prereqs for all of it: VM up, images built, keys seeded —
[BOOTSTRAP.md](BOOTSTRAP.md) if you're starting from zero.
