# Architecture

This document records what the system is, why it is this shape, and which
decisions are load-bearing. If you change a manifest, check the matching
section here first.

## The three tiers

```
Tier 0  macOS host
        Source of truth for code (~/ai-projects/<proj>) and secrets
        (~/.ai-secrets, 0600, shared into the VM read-only). The stack can
        write only ~/ai-projects; nothing else on the Mac is touched.

Tier 1  Lima VM "ai-box"  (vm/ai-box.yaml)
        A disposable appliance: outer dockerd, sysbox runtime, credential
        gateway, registry mirror. No project code, no toolchains, no
        long-lived state worth backing up.

Tier 2  Per-project sandboxes  (sandbox/compose.sandbox.yaml)
        sysbox-runc "system containers" — the ONLY place agents and
        toolchains execute. Ephemeral root filesystems; state only in
        per-project named volumes.
```

### Tier 0 boundary

Lima mounts exactly two paths: `~/ai-projects → /mnt/projects` (writable)
and `~/.ai-secrets → /mnt/secrets` (read-only). The rest of the Mac home
does not exist from the VM's perspective — not read-only, absent. This is
the strongest isolation property in the whole design and it costs nothing.
Keeping the secrets share read-only means a full VM compromise can read
the key file (the gateway must) but can never tamper with or delete the
Mac's only copy. Everything else (user namespaces, cgroup limits, the
gateway) is defense-in-depth behind it.

### Tier 1: why one VM and not N

The alternatives considered (from the design discussions this repo
descends from):

| Option | Verdict | Why |
| --- | --- | --- |
| N VMs (Vagrant/Parallels/VMware) | rejected | N kernels, fragmented pinned RAM, provider port-forward bugs, slow shared folders |
| Lima per project | rejected for daily use | same math: 6-8 GiB per VM for safe Rust builds × 4 projects = dead Mac |
| **One Lima VM + containers** | **chosen** | one kernel, one RAM pool shared dynamically, one image layer cache, virtiofs only where it's fast enough |
| Docker `sbx` | rejected | closed-source binary, mandatory OAuth login to boot a *local* microVM — a rug-pull waiting to happen; otherwise architecturally similar to what we build here |
| DinD sidecars on the Mac's own Docker | rejected | `privileged: true` breaks the boundary, duplicated layer caches, blast radius on your daily-driver daemon |
| Multipass | rejected | Ubuntu-only, sshfs mounts, no auto port-forwarding |

Lima specifics that earned it: `vmType: vz` (Apple Virtualization.framework
— the same hypervisor sbx uses), `mountType: virtiofs` (only host sharing
fast enough for source trees), automatic port-forwarding of anything the
guest binds, declarative YAML, zero accounts, 100% open source.

### Tier 2: why sysbox and not plain containers

A sandbox needs to be *simultaneously* powerful (real root, real docker for
`docker compose up` integration tests) and contained (no `privileged: true`,
no shared daemon). The options:

| Runtime | Real root inside | Own docker | privileged? | Verdict |
| --- | --- | --- | --- | --- |
| plain runc | ✗ (or root = VM root) | socket mount → sibling containers, port collisions | – | fallback only |
| runc + dind sidecar | ✓ | ✓ | **✓ required** | rejected: privileged container on the VM = VM-root-equivalent |
| **sysbox-runc** | ✓ | ✓ private inner daemon | ✗ | **chosen** |

Sysbox achieves it with unprivileged user namespaces: UID 0 inside maps to
a high unprivileged UID (≈165536) on the VM; sysbox-fs virtualizes the
/proc & /sys bits a user-ns can't fake; sysbox-mgr provisions a private
backing store for the inner `/var/lib/docker`. Escape from the inner docker
still lands inside an unprivileged user namespace on the VM.

**The cost, accepted knowingly:** sysbox validates against specific
kernels. We pin the noble GA 6.8 kernel and disable unattended upgrades
(`vm/ai-box.yaml` step 2) so an apt upgrade can't silently break every
sandbox. The escape path is documented in
[UPDATES.md](UPDATES.md#moving-off-the-pinned-kernel), and a plain-runc
fallback profile ships commented in compose.sandbox.yaml for emergencies.

## localhost semantics — the detail that shaped everything

The requirement: inside a sandbox, `docker compose up -d postgres` then
connecting to `localhost:5432` must *just work*, and two projects must be
able to do it *simultaneously*. That is what selecting sysbox buys: the
inner daemon publishes ports into the sandbox's own network namespace,
where "localhost" already points.

The flip side (a classic surprise, internalized in
[RUNBOOK.md](RUNBOOK.md#two-network-layers)): ports inside the sandbox's
namespace are invisible to Lima's auto-forward. To reach them from the Mac,
compose can map a per-project port slice onto the VM (`ports:` block +
`PORT_BASE`), which Lima then forwards. Dev servers run *directly* in the
sandbox (not via inner docker) are in the same situation.

## Image layering = update strategy

Agent CLIs churn weekly; toolchains monthly; OS bases ~never. The stack
ships three flavors — `ai-opencode`, `ai-deepseek`, and `ai-whiteboard` —
with **identical toolchains** (node/typescript, rust, python, go); two
carry one baked agent CLI, whiteboard is a clean slate (bring your
own ad-hoc). Stages are ordered by churn so a volatile bump invalidates the
least cache:

```
base          ubuntu digest-pinned, system tools, inner docker-ce, sysbox tweaks
  └ node-core     fnm + pinned Node LTS + tsc
      └ toolchains   rust (rustup+binstall) + python (uv+managed CPython) + go
          │          ↑ also shipped directly as ai-whiteboard (zero agents)
          ├ opencode   OpenCode TUI + baked opencode.json (OpenCode Go)   ← thin
          └ deepseek   DeepSeek Harness web UI + baked web profile       ← volatile
```

A `just bump-agents && just build` rebuilds only the two agent tails
(~1 min each with warm cache); the heavy toolchains layer is shared
beneath all flavors — including whiteboard, which IS that layer — and only
moves on monthly toolchain bumps. Agents get no runtime
magic — plain binaries on PATH plus a baked provider config (or plain env)
pointing at the credential gateway; per-CLI wiring lives in
[AGENT-CONFIG.md](AGENT-CONFIG.md). Versions are pinned in one file
(`docker-bake.hcl`) and refreshed by `scripts/bump.sh`; `just build` tags
each image `:latest` plus `:YYYYMMDD` so projects can pin known-good days.

Two conventions matter if you edit the Dockerfile:

- **Runtime tools never install under `/root/.config`, `/root/.local`, or
  `/root/.dsh`** — those are volume paths; image content there is hidden
  after the first mount (volume shadowing). All installers point at
  `/usr/local/...`. The one deliberate exception is provider *config* for
  first-mount seeding: OpenCode's `opencode.json` and the DSH web profile.
- **Build caches redirect to `/var/cache/build-targets`** (a volume on the
  VM's native ext4) via `CARGO_TARGET_DIR`, `GOCACHE`, `GOMODCACHE`,
  `npm_config_cache`, `UV_CACHE_DIR`. Never compile across the virtiofs
  `/workspace` mount: source syncs fine, but 10k-file incremental build I/O
  does not.

## Credential gateway

Pattern lifted from Docker sbx, self-hosted: sandboxes hold format-valid
dummy keys and gateway-routed base URLs. The gateway is **protocol-blind**:
it strips a route prefix, forwards the rest of the path to one fixed
upstream, and swaps the dummy `Authorization` value for the real key. It
does not know model ids and does not translate OpenAI/Anthropic/Gemini
payloads — those stay with the harness and the upstream.

Two active routes, one per upstream:

- `/opencode-go/*` → `https://opencode.ai`. The OpenCode TUI owns the
  per-model protocol choice; its native base is
  `https://opencode.ai/inference/go/v1`, so every API family
  (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`,
  `/v1/models/<id>:…`) converges on
  one origin and one Caddy block. Adding a Go model requires no gateway
  change.
- `/deepseek/*` → `https://api.deepseek.com`. The DeepSeek Harness web
  flavor uses an OpenAI-compatible custom provider pointing at
  `/deepseek/v1`.

The gateway listens on the VM's docker0 bridge
(`host.docker.internal:4000`); Caddy terminates plain HTTP, injects the
real key header, and proxies over TLS upstream. For gateway-routed
providers, real keys exist only in `/etc/ai-gateway/secrets.env`
(root:root 0600, seeded from the Mac), never in any env visible to a
sandbox. The commented `/foo` block in
`gateway/Caddyfile` is the gateway-isolated template for a third-party
provider; per-CLI usage is in [AGENT-CONFIG.md](AGENT-CONFIG.md).

Why base-URL swapping and not a MITM proxy by default: zero CA management,
zero overhead on package traffic, deterministic routing; and every agent
in the set can be pointed at an OpenAI/Anthropic-compatible base URL.
MITM remains the escalation when a tool hardcodes a provider host or uses
interactive OAuth that a static key cannot replace.

Why Caddy: path routing, header surgery, env-injected secrets, TLS
verification/SNI on by default, and first-class streaming/WebSocket
pass-through. nginx cannot read env vars without a render step (a second
on-disk key copy), and its upstream TLS verification defaults are the
wrong way for a process injecting live keys. The Caddyfile uses host-only
upstreams; provider base paths are carried by the harness base URL, so
there are no `rewrite` tricks to maintain. `caddy validate` runs during
provisioning before the gateway restarts.

## Registry mirror (and why image pulling repeats at all)

Docker inside this VM behaves exactly like docker on a Mac — and that is
precisely why the mirror exists. The subtlety is that an image cache is
**per-daemon, never per-machine**: it lives in each daemon's own
`/var/lib/docker`. On macOS you run ONE daemon (inside Docker
Desktop's/OrbStack's hidden utility VM), so every project shares one store
and `postgres:16` is downloaded exactly once, ever.

This stack deliberately runs **one daemon per sandbox** (that's the sysbox
isolation: private docker, private store, safe `docker compose up`). Docker
cannot share one image store across concurrent daemons — they corrupt each
other's locks/metadata, and sharing would re-couple projects — so each
inner daemon gets its own `/var/lib/docker` on a per-project named volume.
Consequence: proj-a's agent and proj-b's agent pulling `postgres:16` means
two downloads and two on-disk copies, because neither daemon can see the
other's store. (The OUTER side never duplicates: ai-opencode/ai-deepseek
images are built once on the outer daemon and all sandbox containers share
them copy-on-write. Only images pulled by INNER daemons — test services
like postgres/redis — repeat per project.)

The pull-through mirror (the `REGISTRY_IMAGE` pin in `vm/ai-box.yaml`,
step 5) deduplicates the **network**, not the disk: every daemon (outer
via `daemon.json`, inner via the entrypoint's `--registry-mirror`) pulls
through it, the first fetch of any image goes to Docker Hub, and all later
fetches by any project are served at local-disk speed. It also makes the
post-`vm-rebuild` warm-up cheap, since the mirror's cache dies with the VM
but refills once per image instead of once per project. Disk duplication
per project remains by design — the isolation you bought — and `just
purge <dead-project>` reclaims it.

## Ephemerality ladder

1. **`just shell <p>`** — new container each run: OS-level mutations
   (global packages, /etc, rogue cron) vanish; volumes persist.
2. **`just purge <p>`** — also deletes the project's volumes (inner images,
   caches, agent state). DSH projects use `just dsh-purge <p>` so the
   `dsh-home` volume is included.
3. **`just nuke` / `vm-rebuild`** — VM deleted; survivors are exactly the
   things that live on the Mac (source, secrets template). The rebuild is
   minutes because everything else is code.

## Deliberately out of scope

- mitmproxy egress allowlist (documented ladder step, not built)
- X11/VNC GUI (browser port-forwards + IDE attach-into-container cover the
  real needs — see BOOTSTRAP §IDEs & agent GUIs)
- multi-VM golden-image cloning (single-VM model made it moot)
- CI pipelines, multi-host fleets
