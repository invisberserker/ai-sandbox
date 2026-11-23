# =============================================================================
# ai-sandbox — day-2 operations surface.
# Install just on the Mac:  brew install just
# List tasks:               just --list
# Full reference:          docs/COMMANDS.md
#
# The happy paths:
#   just vm-up && just build && just verify
#   just new proj-alpha && just up proj-alpha
#   just new web-proj  && just up web-proj-dsh   (DeepSeek web UI)
# Weekly:   just bump-agents && just build && just verify
# Idle AM:  just activate            (OpenCode Go keepalive: dad-joke ping)
# Reset:    just vm-rebuild   (VM)  /  just purge proj-alpha  (one project)
#
# FLAVORS: every project verb takes the project name with an optional
# flavor suffix — `test` runs the OpenCode TUI sandbox, `test-dsh` the
# DeepSeek Harness one. BOTH mount the same ~/ai-projects/test dir; the
# suffix namespaces containers/volumes/networks (the compose project
# name) and selects the image. Same flavor twice concurrently is refused
# where it would corrupt (`shell` vs `up` — see the shell guard).
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

# ─── internal plumbing ────────────────────────────────────────────────────────

# internal: print the NAMES of this project-flavor's currently RUNNING
# containers (the `up` service container and any live `shell` one-offs),
# one per line; empty output = nothing running. Exits 0 unconditionally —
# callers capture it with command substitution, and a nonzero exit would
# make the sub-just invocation print a "recipe failed" line on every
# happy-path run (a false alarm). Real failures (VM down) surface from
# the main verb instead.
[private]
running_containers vm project:
    #!/bin/bash
    limactl shell {{vm}} -- bash -lc \
      'docker ps --filter label=com.docker.compose.project={{project}} --filter status=running --format "{{"{{"}}.Names{{"}}"}}"' 2>/dev/null || true

# internal: remove this project-flavor's expose relays (label-scoped).
# Called by clean/purge BEFORE `compose down` so the network removal
# never trips over a relay attached to it.
[private]
sweep_relays vm project:
    #!/bin/bash
    set -euo pipefail
    limactl shell {{vm}} -- bash -lc \
      'ids="$(docker ps -aq --filter label=ai-sandbox.relay={{project}})"; [ -n "$ids" ] && docker rm -f $ids >/dev/null; exit 0'

# internal: docker compose against a project sandbox. The project arg may
# carry a flavor suffix (-dsh today): the suffix picks the override files,
# the image, and the compose project name. The DIR is always the bare name.
# This recipe runs on the MAC (guards check ~/ai-projects, the mount
# source); docker compose itself runs in the VM via limactl shell.
# --project-directory is explicit so bind mounts resolve against the
# project dir; --env-file points at .sandbox.env (never a repo's .env).
# File ORDER matters: compose.ports.yaml (merged only when .sandbox.env
# sets SANDBOX_PORTS=1) comes BEFORE compose.dsh.yaml, so the dsh
# override's `ports: !override` REPLACES the opencode window instead of
# unioning with it (compose >= 2.24 — the same floor the env_file
# `required: false` below relies on).
[private]
compose vm project *args:
    #!/bin/bash
    set -euo pipefail
    p="{{project}}"
    case "$p" in
      *-dsh) base="${p%-dsh}"; flavor="deepseek" ;;
      *)     base="$p";        flavor="opencode" ;;
    esac
    d="$HOME/ai-projects/$base"
    g="/mnt/projects/$base"
    [ -d "$d" ] || { echo "no project dir ~/ai-projects/$base (try: just new $base)" >&2; exit 1; }
    [ -f "$d/.sandbox.env" ] || { echo "no ~/ai-projects/$base/.sandbox.env (try: just new $base)" >&2; exit 1; }
    # optional shared date-tag pin — all flavors build together (just build)
    tag="$(grep -E '^IMAGE_TAG=' "$d/.sandbox.env" | tail -1 | cut -d= -f2 || true)"
    # Legacy SANDBOX_IMAGE (the old per-flavor template shipped it):
    #   same flavor, no tag → stale default: silent, ignored.
    #   same flavor WITH a date tag → a deliberate pin: honor it (the
    #     IMAGE_TAG knob, if also set, wins).
    #   a DIFFERENT flavor → the file picked a flavor by its old name —
    #     say so (delete the line, or use the right verb/suffix).
    img_line="$(grep -E '^SANDBOX_IMAGE=' "$d/.sandbox.env" | tail -1 | cut -d= -f2 || true)"
    if [ -n "$img_line" ]; then
        case "$img_line" in
            "ai-$flavor") ;;
            "ai-$flavor":*) [ -n "$tag" ] || tag="${img_line##*:}" ;;
            *) echo "note: $base/.sandbox.env sets SANDBOX_IMAGE=$img_line — ignored; this verb runs ai-$flavor (flavors are per-verb now: the -dsh suffix runs the DeepSeek one). Remove the line, or move a date pin to IMAGE_TAG=." >&2 ;;
        esac
    fi
    files="{{repo_in_vm}}/sandbox/compose.sandbox.yaml"
    grep -q '^SANDBOX_PORTS=1' "$d/.sandbox.env" \
      && files="$files -f {{repo_in_vm}}/sandbox/compose.ports.yaml" || true
    [ "$flavor" = "deepseek" ] \
      && files="$files -f {{repo_in_vm}}/sandbox/compose.dsh.yaml" || true
    # A FOLLOWING log stream is infinite by design. Ctrl+C travels through
    # the ssh pty as the remote side exiting 130 — the follow's intended
    # end, not a failure. Remap 130 → 0 for follow invocations only, so
    # the stream ends quietly instead of printing "recipe failed" at
    # every just layer. The default dump is finite and gets no special
    # casing (an interrupted dump is a real interruption); every other
    # verb keeps honest failure reporting.
    rc=0
    limactl shell {{vm}} -- bash -lc \
      "cd '$g' && export SANDBOX_IMAGE='ai-$flavor:${tag:-latest}' && docker compose --env-file '$g/.sandbox.env' -f $files --project-directory . --project-name '$p' {{args}}" || rc=$?
    case "{{args}}" in
        logs*\ -f\ *|logs*\ --follow\ *) [ "$rc" -eq 130 ] && exit 0 ;;
    esac
    exit "$rc"

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

# Writes one file only (safe on an existing checkout). NAME must be
# lowercase/digits/-/_ and must not end in a reserved flavor suffix —
# flavors are chosen per invocation, not by this file.
# new NAME — scaffold ~/ai-projects/NAME (OpenCode: `just up NAME`; DeepSeek: `just up NAME-dsh`).
[group('projects')]
new name:
    #!/bin/bash
    set -euo pipefail
    p="{{name}}"
    case "$p" in
        *[!a-z0-9_-]*|'') echo "project name '$p': use lowercase letters, digits, - or _ (it is the compose project name)" >&2; exit 1 ;;
        *-dsh) echo "project name '$p' ends in the reserved -dsh suffix — create the bare dir: just new ${p%-dsh}, then: just up ${p%-dsh}-dsh" >&2; exit 1 ;;
    esac
    d="$HOME/ai-projects/{{name}}"
    mkdir -p "$d"
    if [ ! -f "$d/.sandbox.env" ]; then
        cp "{{repo_dir}}/sandbox/sandbox.env.example" "$d/.sandbox.env"
        echo "created $d/.sandbox.env (flavor-agnostic — the flavor comes from the verb's project-name suffix)"
    else
        echo "$d/.sandbox.env exists — leaving it alone"
    fi
    echo "enter with:   just up {{name}}         (OpenCode TUI; then: just attach {{name}})"
    echo "web UI:       just up {{name}}-dsh      (DeepSeek Harness; URL printed after start)"

# Long agent sessions: `just up` + `just attach` + tmux inside.
# shell NAME[-dsh] [VM] — one-off session; refused if ANY container of this flavor is running.
[group('projects')]
shell name vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    running="$(just -f {{justfile()}} running_containers {{vm}} {{name}})"
    if [ -n "$running" ]; then
        if printf '%s' "$running" | grep -qx "{{name}}-agent-1"; then
            echo "'{{name}}' is already up — use: just attach {{name}}  (a second container would put two inner dockerds on one store)" >&2
        else
            echo "a live just-shell session for '{{name}}' holds the inner docker store:" >&2
            printf '  %s\n' $running >&2
            echo "return to that session, or remove it first: limactl shell {{vm}} -- docker rm -f <name>" >&2
        fi
        exit 1
    fi
    just -f {{justfile()}} compose {{vm}} {{name}} run --rm agent

# The -dsh suffix starts the DeepSeek Harness flavor and prints its macOS
# URL + the first-auth hint after start. Refused while a live `shell`
# session of that flavor holds the store — its container shares the up
# sandbox's inner-docker-data, and two inner dockerds corrupt it.
# up NAME[-dsh] [VM] — sandbox runs in the background; live context survives across days.
[group('projects')]
up name vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    running="$(just -f {{justfile()}} running_containers {{vm}} {{name}})"
    strays="$(printf '%s' "$running" | grep -vx "{{name}}-agent-1" || true)"
    if [ -n "$strays" ]; then
        echo "a live just-shell session for '{{name}}' holds the inner docker store:" >&2
        printf '  %s\n' $strays >&2
        echo "remove it before starting the up sandbox: limactl shell {{vm}} -- docker rm -f <name>" >&2
        exit 1
    fi
    just -f {{justfile()}} compose {{vm}} {{name}} up -d
    p="{{name}}"
    case "$p" in
      *-dsh)
        port="$(grep -E '^DSH_PORT=' "$HOME/ai-projects/${p%-dsh}/.sandbox.env" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
        echo "DSH web UI:  http://localhost:${port:-3080}"
        echo "first auth:  just logs {{name}} — open the /deepseek?token=… link it prints"
        ;;
    esac

# attach NAME[-dsh] [VM] — shell into a running sandbox; exit stops nothing.
[group('projects')]
attach name vm=vm_name:
    just -f {{justfile()}} compose {{vm}} {{name}} exec agent bash

# (the dsh web launcher prints its URL/token here on every boot). REFUSED
# without an up'd container: a live `just shell` session's log is the
# raw TUI escape stream — it floods your terminal and can wedge the
# keyboard protocol (docs/FAQ.md).
# logs NAME[-dsh] [-f] [VM] — print a running sandbox's log (dsh URL/token), like docker logs.
[group('projects')]
logs name follow="" vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    case "{{follow}}" in
        ""|-f|--follow) ;;
        *) echo "unknown flag '{{follow}}' — want -f (or --follow) to stream, or nothing to print and exit" >&2; exit 1 ;;
    esac
    running="$(just -f {{justfile()}} running_containers {{vm}} {{name}})"
    if ! printf '%s' "$running" | grep -qx "{{name}}-agent-1"; then
        echo "no running sandbox '{{name}}' — if you are in a just shell session, its log is the raw TUI escape stream (terminal-flooding; see docs/FAQ.md)" >&2
        exit 1
    fi
    # Default mirrors docker logs / kubectl logs: print the last 100
    # lines and exit. -f/--follow streams live instead; the compose
    # recipe remaps that follow's Ctrl+C exit (130) to 0 — see its
    # comment there.
    farg="{{follow}}"
    just -f {{justfile()}} compose {{vm}} {{name}} logs --tail 100 $farg agent

# clean NAME[-dsh] [VM] — compose down for this flavor (containers, network, relays); volumes kept.
[group('projects')]
clean name vm=vm_name:
    just -f {{justfile()}} sweep_relays {{vm}} {{name}}
    just -f {{justfile()}} compose {{vm}} {{name}} down

# purge NAME[-dsh] [VM] — tier-2 reset for this flavor: wipe its volumes; prompts y/N.
[group('projects')]
purge name vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    read -r -p "wipe volumes for '{{name}}' (inner images, caches, agent state)? [y/N] " a
    [ "$a" = "y" ] || exit 0
    just -f {{justfile()}} sweep_relays {{vm}} {{name}}
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

# ─── reach sandbox ports from the Mac (opt-in window / ad-hoc relay) ──────────
# Two paths, mirroring the ecosystems' own split:
#   declarative: SANDBOX_PORTS=1 + a PORT_BASE window in .sandbox.env —
#                published on every `just up`, identity mapping
#                (sandbox port N → Mac localhost:N).
#   imperative:  just expose — one port, one command, ephemeral relay.
#   just expose test 3000             Mac localhost:3000 → test :3000
#   just expose test-dsh 3001:3000    Mac localhost:3001 → test-dsh :3000
#   just expose test                  discovery: listeners + relay status

# The relay joins the project's compose network and targets the compose
# service name (`agent`), so a sandbox recreate (new IP) is absorbed
# automatically via DNS — no re-expose needed. Works for up'd sandboxes
# AND live `just shell` sessions. Conflict on a taken VM port → the
# error suggests another Mac-side number.
# expose NAME[-dsh] [HOST[:CONTAINER]] [VM] — forward one sandbox port to macOS localhost.
[group('projects')]
expose name spec="" vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    if [ -z "{{spec}}" ]; then
        # discovery: what is listening inside the sandbox + relay status
        limactl shell {{vm}} -- bash -lc '
          cid="$(docker ps -q --filter label=com.docker.compose.project={{name}} | head -1)"
          if [ -z "$cid" ]; then
            echo "no running sandbox for {{name}} (try: just up {{name}} or a live just shell)" >&2
            exit 1
          fi
          echo "== listeners inside {{name}} =="
          (
            if docker exec "$cid" ss -ltnH >/dev/null 2>&1; then
              docker exec "$cid" ss -ltnH | awk "{print \$4}" | sed "s/.*://" | sort -un
            else
              docker exec "$cid" cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | while read -r _ l _ st _; do
                [ "$st" = "0A" ] && printf "%d\n" "0x${l##*:}"
              done | sort -un
            fi
          ) | sed "/^$/d" | while read -r port; do
            echo "  :$port    →    just expose {{name}} $port"
          done
          echo
          echo "== relays for {{name}} =="
          if [ -n "$(docker ps -q --filter label=ai-sandbox.relay={{name}})" ]; then
            docker ps --filter label=ai-sandbox.relay={{name}} --format "{{"{{"}}.Names{{"}}"}}  →  {{"{{"}}.Label \"ai-sandbox.target\"{{"}}"}}"
          else
            echo "  (none)"
          fi
        '
        exit 0
    fi
    limactl shell {{vm}} -- bash -lc '
      set -e
      spec="{{spec}}"
      if ! echo "$spec" | grep -qE "^[0-9]+(:[0-9]+)?$"; then
        echo "bad spec $spec — want [HOST[:CONTAINER]], e.g. 3000 or 3001:3000" >&2
        exit 1
      fi
      target="${spec##*:}"
      host="${spec%%*:}"
      cid="$(docker ps -q --filter label=com.docker.compose.project={{name}} | head -1)"
      if [ -z "$cid" ]; then
        echo "no running sandbox {{name}} to relay from (try: just up {{name}} or a live just shell)" >&2
        exit 1
      fi
      docker rm -f {{name}}-expose-$host >/dev/null 2>&1 || true
      if ! docker run -d --rm --name {{name}}-expose-$host \
           --network {{name}}_default \
           -p 127.0.0.1:$host:$host \
           --label ai-sandbox.relay={{name}} \
           --label ai-sandbox.target=agent:$target \
           alpine/socat tcp-listen:$host,fork,reuseaddr tcp:agent:$target; then
        echo "could not claim VM port $host (a window or another relay holds it?)" >&2
        echo "try another Mac-side number:  just expose {{name}} ALT:$target" >&2
        exit 1
      fi
      echo "exposed: Mac localhost:$host → {{name}} :$target"
    '

# `just unexpose --all my-box` passes the VM name in the second slot.
# No y/N on --all: relays carry no data (re-running `expose` restores).
# Three widening scopes:
#   just unexpose test 3001     the :3001 claim
#   just unexpose test          every relay of that flavor
#   just unexpose --all         every relay on the VM ("start clean")
# unexpose NAME[-dsh] [HOST[:CONTAINER]] [VM] — release relays; `--all` = every relay on the VM.
[group('projects')]
unexpose name spec="" vm=vm_name:
    #!/bin/bash
    set -euo pipefail
    if [ "{{name}}" = "--all" ]; then
        vmname="{{vm}}"
        [ -n "{{spec}}" ] && vmname="{{spec}}" || true
        limactl shell "$vmname" -- bash -lc '
          ids="$(docker ps -aq --filter label=ai-sandbox.relay)"
          if [ -z "$ids" ]; then
            echo "0 relays exposed — already clean"
            exit 0
          fi
          docker ps -a --filter label=ai-sandbox.relay --format "{{"{{"}}.Names{{"}}"}}  →  {{"{{"}}.Label \"ai-sandbox.target\"{{"}}"}}"
          docker rm -f $ids >/dev/null
          echo "released $(echo "$ids" | wc -l | tr -d " ") relay(s) — the VM is clean"
        '
        exit 0
    fi
    key="{{spec}}"
    case "$key" in *:*) key="${key%%:*}" ;; esac
    if [ -z "$key" ]; then
        limactl shell {{vm}} -- bash -lc '
          ids="$(docker ps -aq --filter label=ai-sandbox.relay={{name}})"
          if [ -z "$ids" ]; then
            echo "no relays for {{name}}"
            exit 0
          fi
          docker ps -a --filter label=ai-sandbox.relay={{name}} --format "{{"{{"}}.Names{{"}}"}}  →  {{"{{"}}.Label \"ai-sandbox.target\"{{"}}"}}"
          docker rm -f $ids >/dev/null
          echo "released all relays for {{name}}"
        '
    else
        limactl shell {{vm}} -- bash -lc "docker rm -f {{name}}-expose-$key >/dev/null 2>&1 && echo \"released {{name}} claim on :$key\" || echo \"no relay: {{name}}-expose-$key\""
    fi

# ─── deepseek helpers ─────────────────────────────────────────────────────────
# The dsh flavor is a suffix, not a verb family: `just up <p>-dsh`,
# `just clean <p>-dsh`, `just logs <p>-dsh` (URL/token), `just purge
# <p>-dsh`, `just expose <p>-dsh HOST[:PORT]`. The one bare-name
# convenience left is dsh-url: it only reads the project dir on the Mac
# (no VM roundtrip).

# The first-auth token is NOT here — it lives in the startup logs:
# `just logs <p>-dsh`.
# dsh-url NAME — print the plain macOS URL for a dsh project.
[group('projects')]
dsh-url name:
    #!/bin/bash
    set -euo pipefail
    f="$HOME/ai-projects/{{name}}/.sandbox.env"
    port="$(grep -E '^DSH_PORT=' "$f" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
    echo "http://localhost:${port:-3080}"

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
      gw="$(ip -4 addr show dev docker0 | grep -o "inet [0-9.]*" | head -1 | cut -d " " -f2)"
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
