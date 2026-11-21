# =============================================================================
# ai-sandbox — day-2 operations surface.
# Install just on the Mac:  brew install just
# List tasks:               just --list
# Full reference:          docs/COMMANDS.md
#
# The happy paths:
#   just vm-up && just build && just verify
#   just new proj-alpha ai-opencode && just shell proj-alpha
#   just new dsh-proj ai-deepseek && just dsh-up dsh-proj
# Weekly:   just bump-agents && just build && just verify
# Idle AM:  just activate            (OpenCode Go keepalive: dad-joke ping)
# Reset:    just vm-rebuild   (VM)  /  just purge proj-alpha  (one project)
#
# VM names: commands take the VM name as a trailing argument
# (just vm-up my-box), else $VM_NAME from your shell or .just.env,
# else "ai-box". VM build settings (guest user, sizing): .lima.env —
# one limactl --set per line, applied at creation.
# =============================================================================

# .just.env (optional, gitignored): a VM_NAME=… line here becomes the
# ambient default. Shell env wins; a missing file is a no-op.
set dotenv-path := ".just.env"

# Name resolution: CLI arg → $VM_NAME (shell beats .just.env) → "ai-box".
vm_name    := env_var_or_default("VM_NAME", "ai-box")
repo_dir   := justfile_directory()
repo_in_vm := "/mnt/projects/ai-sandbox" # the repo as seen INSIDE the VM

# internal: docker compose against a project sandbox. The recipe runs on
# the MAC (guard checks ~/ai-projects, the mount source); docker compose
# itself runs in the VM via limactl shell.
# --project-directory is explicit so bind mounts resolve against the project
# dir; --env-file points at .sandbox.env (never a repo's own .env).
[private]
compose vm project *args:
    #!/bin/bash
    set -euo pipefail
    p="$HOME/ai-projects/{{project}}"
    g="/mnt/projects/{{project}}"
    [ -d "$p" ] || { echo "no project dir ~/ai-projects/{{project}} (try: just new {{project}})" >&2; exit 1; }
    [ -f "$p/.sandbox.env" ] || { echo "no ~/ai-projects/{{project}}/.sandbox.env (try: just new {{project}})" >&2; exit 1; }
    limactl shell {{vm}} -- bash -lc \
      "cd '$g' && docker compose --env-file '$g/.sandbox.env' -f {{repo_in_vm}}/sandbox/compose.sandbox.yaml --project-directory . --project-name {{project}} {{args}}"

# internal: same as compose, plus the DSH port/volume override.
[private]
compose_dsh vm project *args:
    #!/bin/bash
    set -euo pipefail
    p="$HOME/ai-projects/{{project}}"
    g="/mnt/projects/{{project}}"
    [ -d "$p" ] || { echo "no project dir ~/ai-projects/{{project}} (try: just new {{project}})" >&2; exit 1; }
    [ -f "$p/.sandbox.env" ] || { echo "no ~/ai-projects/{{project}}/.sandbox.env (try: just new {{project}})" >&2; exit 1; }
    limactl shell {{vm}} -- bash -lc \
      "cd '$g' && docker compose --env-file '$g/.sandbox.env' -f {{repo_in_vm}}/sandbox/compose.sandbox.yaml -f {{repo_in_vm}}/sandbox/compose.dsh.yaml --project-directory . --project-name {{project}} {{args}}"

# ─── VM lifecycle ─────────────────────────────────────────────────────────────

[group('vm')]
vm-up name=vm_name:
    #!/bin/bash
    set -euo pipefail
    command -v limactl >/dev/null 2>&1 || { echo "lima missing: brew install lima" >&2; exit 1; }
    # Both lima mounts must exist on the Mac before start (secrets share is
    # read-only — created once, edited by hand, never written by the stack).
    mkdir -p ~/ai-projects ~/.ai-secrets
    # .lima.env (optional, gitignored): creation-time lima overrides, one
    # limactl --set per `path=value` line. Creation only — see .lima.env.example.
    LIMA_ENV="{{repo_dir}}/.lima.env"
    exists=0
    if limactl list -q 2>/dev/null | grep -q '^{{name}}$'; then exists=1; fi
    set --
    if [ -f "$LIMA_ENV" ]; then
        if [ "$exists" = 1 ]; then
            echo "VM '{{name}}' exists — .lima.env applies at creation only (just vm-rebuild to apply)" >&2
        else
            while IFS='=' read -r k v; do
                case "$k" in ''|'#'*) continue ;; esac
                [ -n "$v" ] || continue
                k="${k#.}"
                # limactl --set takes JSON-ish values: bare numbers and
                # bools pass through; everything else gets quoted.
                if [ "$v" = true ] || [ "$v" = false ] || [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                    :
                elif [[ "$v" == \"* ]]; then
                    :
                else
                    v="\"$v\""
                fi
                set -- "$@" --set ".${k}=${v}"
            done < "$LIMA_ENV"
        fi
    fi
    # `limactl start NAME` starts an existing instance (no-op if running);
    # the FILE form creates one. --set is creation-only.
    if [ "$exists" = 1 ]; then
        limactl start "{{name}}"
    else
        limactl start --name={{name}} "$@" "{{repo_dir}}/vm/ai-box.yaml"
    fi
    # Docker group for the VM user — every compose command needs it.
    # Applied here after the boot: an authenticated session as that user,
    # with lima's passwordless sudo. Idempotent; follows .lima.env user.name.
    limactl shell {{name}} -- bash -lc 'u="$(id -un)"; sudo usermod -aG docker "$u" && id -nG "$u" | grep -qw docker && echo "VM user $u is in the docker group"' \
      || { echo "FAILED to add the VM user to the docker group — run inside vm-shell: sudo usermod -aG docker \$(id -un)" >&2; exit 1; }
    # Sessions opened before the usermod keep their old groups; refresh
    # the ssh master and verify like a fresh session sees it.
    limactl shell --reconnect {{name}} -- bash -lc 'id -nG | grep -qw docker && echo "confirmed: new sessions see the docker group"' \
      || { echo "the group is set but a fresh session does not see it — try: limactl shell --reconnect {{name}}" >&2; exit 1; }
    if [ "{{name}}" = "{{vm_name}}" ]; then
        echo "VM '{{name}}' up. Next: just build && just verify"
    else
        echo "VM '{{name}}' up. Next: just build {{name}} && just verify {{name}}"
    fi

[group('vm')]
vm-stop name=vm_name:
    limactl stop {{name}}

[group('vm')]
vm-shell name=vm_name:
    limactl shell {{name}}

# vm-rebuild [NAME] — delete + recreate the VM and rebuild images
[group('vm')]
vm-rebuild name=vm_name:
    #!/bin/bash
    set -euo pipefail
    # Survivors: source + secrets template (Mac). Casualties: image cache,
    # per-project volumes, mirror cache. First pull after is full-size.
    limactl delete -f {{name}}
    just -f {{justfile()}} vm-up {{name}}
    just -f {{justfile()}} build {{name}}

[group('vm')]
status name=vm_name:
    #!/bin/bash
    set -euo pipefail
    echo "== VM '{{name}}' =="
    limactl list {{name}} 2>/dev/null || echo "  (not created)"
    if limactl list -q 2>/dev/null | grep -q '^{{name}}$'; then
        echo "-- kernel/holds --"
        limactl shell {{name}} -- bash -lc 'uname -r; apt-mark showhold | grep ^linux | head -5'
        echo "-- docker/sysbox --"
        limactl shell {{name}} -- bash -lc \
          'docker --version; dpkg -s sysbox-ce 2>/dev/null | grep ^Version; docker info 2>/dev/null | grep -i "^ *Runtimes:"'
        echo "-- local images --"
        limactl shell {{name}} -- bash -lc \
          'docker images | grep -E "ai-(base|whiteboard|opencode|deepseek)" || echo "  (none — run: just build)"'
    fi

# ─── images ───────────────────────────────────────────────────────────────────

[group('images')]
build name=vm_name:  # build base + all three flavors (whiteboard/opencode/deepseek)
    just -f {{justfile()}} _bake default {{name}}

[private]
_bake group name:
    #!/bin/bash
    set -euo pipefail
    # IMAGE_TAG flows into docker-bake.hcl via getenv() (see the hcl header)
    export IMAGE_TAG="$(date +%Y%m%d)"
    limactl shell {{name}} -- env IMAGE_TAG="$IMAGE_TAG" bash -lc \
      "cd {{repo_in_vm}}/images && docker buildx bake -f docker-bake.hcl {{group}}"

# bump-agents — refresh agent CLI pins, then rebuild only their tails
[group('images')]
bump-agents:
    bash "{{repo_dir}}/scripts/bump.sh" --agents

[group('images')]
bump-all:
    bash "{{repo_dir}}/scripts/bump.sh" --all

[group('images')]
verify name=vm_name:
    limactl shell {{name}} -- bash {{repo_in_vm}}/scripts/verify.sh

# ─── projects / sandboxes ─────────────────────────────────────────────────────

# new NAME [IMAGE] — scaffold ~/ai-projects/NAME with a .sandbox.env.
# Writes one file only (safe on an existing checkout). NAME must be
# lowercase/digits/-/_ — it becomes the compose project name.
[group('projects')]
new name image="ai-opencode:latest":
    #!/bin/bash
    set -euo pipefail
    case "{{name}}" in
        *[!a-z0-9_-]*|'') echo "project name '{{name}}': use lowercase letters, digits, - or _ (it is the compose project name)" >&2; exit 1 ;;
    esac
    d="$HOME/ai-projects/{{name}}"
    mkdir -p "$d"
    if [ ! -f "$d/.sandbox.env" ]; then
        sed "s|^SANDBOX_IMAGE=.*|SANDBOX_IMAGE={{image}}|" \
            "{{repo_dir}}/sandbox/sandbox.env.example" > "$d/.sandbox.env"
        echo "created $d/.sandbox.env (image -> {{image}})"
    else
        echo "$d/.sandbox.env exists — leaving it alone"
    fi
    case "{{image}}" in
        ai-deepseek*) echo "start with:  just dsh-up {{name}}   (opens a web UI on localhost)" ;;
        *)           echo "enter with:  just shell {{name}}" ;;
    esac

# shell NAME [VM] — one-off session: fresh container OS, removed at exit.
[group('projects')]
shell name vm=vm_name:
    # Long agent sessions: `just up` + `just attach` + tmux inside.
    just -f {{justfile()}} compose {{vm}} {{name}} run --rm agent

# up NAME [VM] — sandbox runs in the background; live context (TUI, tmux,
# servers) survives across days. Required for the ports: block.
[group('projects')]
up name vm=vm_name:
    just -f {{justfile()}} compose {{vm}} {{name}} up -d

# attach NAME [VM] — shell into a running sandbox; exit stops nothing.
[group('projects')]
attach name vm=vm_name:
    just -f {{justfile()}} compose {{vm}} {{name}} exec agent bash

# clean NAME [VM] — stop/remove containers + network; volumes kept
[group('projects')]
clean name vm=vm_name:
    just -f {{justfile()}} compose {{vm}} {{name}} down

# purge NAME [VM] — tier-2 reset: wipe project volumes (source on Mac untouched)
[group('projects')]
purge name vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    read -r -p "wipe volumes for '{{name}}' (inner images, caches, agent state)? [y/N] " a
    [ "$a" = "y" ] || exit 0
    just -f {{justfile()}} compose {{vm}} {{name}} down -v

# activate [VM] — the whole idle-morning ritual as one command: `new` a
# burner sandbox, run the dad-joke curl inside it (scripts/go-keepalive.sh
# — opens/refreshes the plan's 5-hour rolling window), exit, purge the
# volumes, rm -rf the burner dir. No typing, no prompts, no residue; the
# scripted session is TTY-less (-T), so cron/launchd works too. The fixed
# burner name `go-keepalive` is owned by this recipe — a run killed
# midway is healed by the next one; never put real work there.
# activate [VM] — keepalive ping for the OpenCode Go 5h rolling window.
[group('projects')]
activate vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    name="go-keepalive"
    d="$HOME/ai-projects/$name"   # the burner dir — ../go-keepalive when
                                  # the repo sits at ~/ai-projects/ai-sandbox
    # 1. just new — scaffold the burner (idempotent: writes .sandbox.env
    #    only once; an existing checkout is left alone).
    just -f {{justfile()}} new "$name"
    # 2. just shell, minus the keyboard: the one-liner rides the project
    #    mount (the file cp'd below is /workspace/go-keepalive.sh inside
    #    the sandbox); `run --rm` = the shell recipe's fresh-container,
    #    removed-at-exit semantics; -T = nothing needs a TTY. A failed
    #    ping must still reach the cleanup below, so capture, don't abort.
    cp "{{repo_dir}}/scripts/go-keepalive.sh" "$d/go-keepalive.sh"
    rc=0
    just -f {{justfile()}} compose "{{vm}}" "$name" run --rm -T agent bash /workspace/go-keepalive.sh || rc=$?
    # 3. exit the shell (implicit: the script ends, --rm reaps the
    #    container), then the purge half: `down -v` = just purge minus the
    #    y/N prompt (this project is seconds old), and rm -rf the burner
    #    dir. Unconditional — a failed or killed run leaves nothing
    #    behind, and the fixed name self-heals any residue it finds.
    just -f {{justfile()}} compose "{{vm}}" "$name" down -v || true
    rm -rf "$d"
    [ "$rc" -eq 0 ] || { echo "activation failed (hints above); burner '$name' swept anyway" >&2; exit "$rc"; }
    echo "opencode go window activated on '{{vm}}' — burner '$name' swept."

# ─── DSH (DeepSeek Harness web UI) ───────────────────────────────────────────
# The dsh flavor runs its web UI inside a sysbox sandbox. The override adds
# the port mapping and dsh-home volume; open the printed localhost URL on
# macOS. Each concurrent DSH project needs its own DSH_PORT in .sandbox.env.

# start a dsh web sandbox + print its macOS URL
[group('projects')]
dsh-up name vm=vm_name:
    just -f {{justfile()}} compose_dsh {{vm}} {{name}} up -d
    just -f {{justfile()}} dsh-url {{name}}

# print the macOS URL for a dsh project
[group('projects')]
dsh-url name:
    #!/bin/bash
    set -euo pipefail
    f="$HOME/ai-projects/{{name}}/.sandbox.env"
    port="$(grep -E '^DSH_PORT=' "$f" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    echo "http://localhost:${port:-3080}"

# follow dsh container logs (startup prints the URL/token)
[group('projects')]
dsh-logs name vm=vm_name:
    just -f {{justfile()}} compose_dsh {{vm}} {{name}} logs -f agent

# stop/remove the dsh container; volumes kept
[group('projects')]
dsh-stop name vm=vm_name:
    just -f {{justfile()}} compose_dsh {{vm}} {{name}} down

# tier-2 reset for dsh: also wipes dsh-home + other volumes
[group('projects')]
dsh-purge name vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    read -r -p "wipe volumes for '{{name}}' (dsh state, inner images, caches)? [y/N] " a
    [ "$a" = "y" ] || exit 0
    just -f {{justfile()}} compose_dsh {{vm}} {{name}} down -v

# ─── secrets / gateway ────────────────────────────────────────────────────────

# Re-seed gateway keys after editing ~/.ai-secrets/ai-gateway.env
[group('secrets')]
seed-secrets name=vm_name:
    limactl shell {{name}} -- sudo bash {{repo_in_vm}}/scripts/seed-secrets.sh

# gateway-reload [NAME] — copy Caddyfile to VM, validate, restart gateway
[group('secrets')]
gateway-reload name=vm_name:
    #!/bin/bash
    set -euo pipefail
    # Run after editing routes (adding a third-party provider, etc.).
    # The file travels over SSH (limactl copy), NOT through the virtiofs
    # mount: the guest's page cache can serve stale content for a
    # recently-edited host file; a reload must install exactly what is
    # on the Mac's disk.
    limactl copy "{{repo_dir}}/gateway/Caddyfile" "{{name}}:/tmp/ai-gateway-Caddyfile"
    limactl shell {{name}} -- sudo bash -lc '
      set -euo pipefail
      install -m 0644 /tmp/ai-gateway-Caddyfile /etc/ai-gateway/Caddyfile
      rm -f /tmp/ai-gateway-Caddyfile
      # Refresh docker0'"'"'s address for the {$DOCKER_GATEWAY} bind in case
      # the daemon re-allocated the bridge subnet since provisioning.
      gw="$(ip -4 addr show dev docker0 | grep -o "inet [0-9.]*" | head -1 | cut -d" " -f2)"
      [ -n "$gw" ] || { echo "docker0 has no IPv4 — is the daemon up?" >&2; exit 1; }
      printf "DOCKER_GATEWAY=%s\n" "$gw" > /etc/ai-gateway/bridge.env
      set -a; . /etc/ai-gateway/bridge.env; set +a
      /usr/local/bin/caddy validate --config /etc/ai-gateway/Caddyfile --adapter caddyfile
      systemctl restart ai-gateway
    '

# ─── last resort ──────────────────────────────────────────────────────────────

# Delete the VM entirely (tier-3 reset). Source + secrets survive on the Mac.
[group('vm')]
nuke name=vm_name:
    #!/bin/bash
    set -euo pipefail
    read -r -p "DELETE VM '{{name}}' (all volumes/caches/images die; rebuild = vm-rebuild)? [y/N] " a
    [ "$a" = "y" ] || exit 0
    limactl delete -f {{name}}
    echo "gone. recreate with: just vm-up {{name}} && just build {{name}}"
