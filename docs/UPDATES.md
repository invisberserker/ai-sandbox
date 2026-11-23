# Updates & rebuilds

Everything in this stack is designed to be thrown away and re-derived.
This page is the runbook for the four update motions, fast to slow.

## The one rule

**Version pins live in exactly two files.** `images/docker-bake.hcl` owns
every image pin (base digest, node, agent CLIs, toolchains, uv). `vm/ai-box.yaml`
owns the VM's pins (sysbox, caddy, registry, Ubuntu image URLs). Touching
anything else to "update something" is a bug. There is no third copy of any
pin: the Dockerfile takes the base image ref as a build-arg from bake
(`UBUNTU_IMAGE`), and its tag-form ARG default only serves bare `docker
build` runs that skip bake.

## 1. Refresh agent CLIs (the weekly habit)

```bash
just bump-agents      # scripts/bump.sh rewrites the pins in docker-bake.hcl
                      # from npm / GitHub — fetch failures skip, never guess
just build            # layer cache absorbs base+node-core+toolchains;
                      # rebuilds the two thin agent tails (~1 min each;
                      # whiteboard needs no rebuild — it IS toolchains)
just verify
```

Running sandboxes keep their old image until restarted — the running
container is immutable. A fresh `just shell <p>` (or `clean` + `up`) picks
up the new `:latest`; for the DeepSeek flavor: `clean <p>-dsh` +
`up <p>-dsh`.

Notes:

- `bump-agents` covers exactly the two CLI pins (one per flavor:
  opencode, dsh). `uv` lives in the shared toolchains layer — refresh it
  with `just bump-all`.
- `NODE_VERSION` is **major-pinned** — `bump-all` only ever takes newer
  releases within the major it reads from docker-bake.hcl. Moving majors
  (e.g. 26 → 28) is a deliberate, manual edit of that file.
- `PYTHON_VERSION` is **not** auto-bumped — a minor bump changes
  interpreter semantics; do it by hand in `docker-bake.hcl`.
- Want to pin a project to a known-good day? Its `.sandbox.env`:
  `IMAGE_TAG=20261120` — `just build` stamps date tags alongside
  `:latest` on every run, and the pin applies to every flavor of the
  project (they are built together).

## 2. Refresh toolchains (monthly-ish)

```bash
just bump-all         # patches within the pinned node major, typescript,
                      # fnm, uv, go, rust stable, cargo-binstall, and the
                      # ubuntu base digest
just build
just verify
```

Expect a fuller rebuild (base digest change invalidates everything): ~10-15
min with the mirror's help. If only Rust moved, the shared `toolchains`
layer and its two agent tails rebuild; base and node-core stay cached.

## 3. Rebuild the VM (when you want a clean slate, or sizing changed)

```bash
just vm-rebuild       # limactl delete + start + build
```

What survives (because it lives on the Mac):

- all project source (`~/ai-projects/*`),
- the secrets file (`~/.ai-secrets/ai-gateway.env`) — provisioning
  re-seeds the gateway automatically at boot from the read-only share.

What dies (by design, all re-derivable):

- the outer image cache (`just build` re-derives it; the mirror's cache
  dies too, so the first pull of each base layer after a rebuild is
  full-size, and later pulls are local),
- every project's named volumes: inner docker images, build caches,
  agent state, and DSH state. DSH's baked profile re-seeds on first
  mount; provider auth is the dummy gateway wiring, so no login is lost.
  **If you care about a project's inner images or DSH sessions, re-plan
  before `vm-rebuild`** — there is no volume export path by design; the
  cheap insurance is `just verify` after rebuild,
- the registry mirror's cache (it refills as sandboxes pull).

For size changes it's the same path — `limactl` can't resize a VM in
place; pass overrides on the fresh start:

```bash
limactl stop ai-box && limactl delete ai-box
limactl start --name=ai-box --set '.cpus=8' --set '.memory="24GiB"' \
    ~/ai-projects/ai-sandbox/vm/ai-box.yaml
just build
```

## 4. Moving off the pinned kernel

Sysbox CE is the one component that constrains the kernel. The VM holds
the noble GA 6.8 kernel and disables unattended-upgrades to protect it.
When you *want* a newer kernel/OS, do it deliberately:

1. Check the [sysbox releases](https://github.com/nestybox/sysbox/releases)
   for a version supporting the target kernel. If none: stop here. This is
   the compromise you accepted; the fallback profile below is the stopgap.
2. Bump `SYSBOX_VERSION` in `vm/ai-box.yaml` (step 4) if needed.
3. Prefer the clean path — new kernel family ⇒ rebuild the VM rather than
   in-place upgrade:

   ```bash
   just vm-shell
   sudo apt-mark unhold $(apt-mark showhold | grep ^linux)   # or edit the yaml
   sudo apt update && sudo apt install --install-recommends linux-generic-hwe-24.04
   sudo reboot
   # after reboot: sysbox-mgr/fs running? sandbox boots? (just verify)
   # if good: re-hold the NEW kernel the same way provisioning does
   ```

4. If sysbox breaks mid-flight, sandboxes fail to start with runc errors.
   Flip a project to the fallback profile (commented at the bottom of
   `sandbox/compose.sandbox.yaml`): `runtime: runc`, the outer docker
   socket mount, and the `SANDBOX_NO_DOCKERD=1` env (the entrypoint then
   skips its inner dockerd and the socket cleanup that would otherwise
   rm the mounted socket). You lose per-project docker isolation and
   port collision-freedom — treat it as a crutch while you roll back the
   kernel (`sudo apt install linux-image-6.8.0-XX-generic && update-grub
   && reboot`, holds back on) or wait for a sysbox release.

## Ubuntu release bumps (24.04 → next LTS)

Same principle: point the `images:` URLs in `vm/ai-box.yaml` at the new
release **only after** sysbox documents support for its default kernel,
bump `SYSBOX_VERSION`, then `just vm-rebuild`. The image side is
independent — the base ref (and its digest) is owned by
`docker-bake.hcl`; the tag-form `UBUNTU_IMAGE` default in the Dockerfile
only serves bare `docker build` runs that skip bake. Refresh it with
`just bump-all`.

## What updates NEVER touch

- Project source (Mac), secrets (Mac), per-project `.sandbox.env`s.
- Anything on the Mac outside `~/ai-projects`.
- Other projects' volumes — `vm-rebuild` aside, motions 1-2 are
  per-image, motion 3 per-VM, never per-neighbor-project.
