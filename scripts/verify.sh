#!/usr/bin/env bash
# =============================================================================
# verify.sh — smoke tests for the whole stack. Runs INSIDE the VM
# (`just verify` wraps: limactl shell <vm> -- bash <repo>/scripts/verify.sh).
#
# Four sections:
#   VM        : outer daemon, sysbox registration, kernel hold, mirror, gateway
#   images    : toolchain binaries answer --version (fast; entrypoint bypassed)
#   sandbox   : ONE full sysbox boot — inner dockerd up, PRIVATE (docker ps
#               empty), user namespace really in effect, OpenCode functional
#   conc      : all three flavors of ONE dir at once (suffix model) —
#               disjoint volumes, opt-in dsh window via !override, OS-env
#               image precedence, one expose relay
#
# Deliberately NOT set -e: we want the full report, not first-fail abort.
# Exit code is nonzero iff anything failed.
# =============================================================================
set -uo pipefail

PASS=0
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

# docker0's address is runtime information: the daemon allocates the
# default bridge wherever it fits (172.20.0.0/16 met in the wild, not
# the classic 172.17.0.0/16), so never assume 172.17.0.1 here.
GW_ADDR="$(ip -4 addr show dev docker0 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | cut -d' ' -f2)"

gw_code() { # gw_code <path> [auth-value]
  local path="$1" auth="${2:-sandbox-dummy}"
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${auth}" \
    "http://${GW_ADDR}:4000${path}" 2>/dev/null
}

echo "== VM =="
if docker info >/dev/null 2>&1; then ok "outer dockerd is up"; else bad "outer dockerd is up"; fi

if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q sysbox-runc; then
  ok "sysbox-runc runtime registered"
else
  bad "sysbox-runc runtime registered (provisioning step 4 failed?)"
fi

if apt-mark showhold 2>/dev/null | grep -q '^linux-image'; then
  ok "kernel packages are held (sysbox compatibility)"
else
  bad "kernel packages are held — an upgrade can break sysbox (vm/ai-box.yaml step 2)"
fi

if curl -sf -o /dev/null http://127.0.0.1:5000/v2/; then
  ok "registry mirror responds on /v2/"
else
  bad "registry mirror responds on /v2/ (vm/ai-box.yaml step 5)"
fi

GW_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${GW_ADDR}:4000/" 2>/dev/null)"
if [ "$GW_CODE" = "403" ]; then
  ok "credential gateway default-denies on / (403)"
else
  bad "credential gateway on / returned '${GW_CODE:-no answer}' (want 403)"
fi

# Needs sudo: /etc/ai-gateway is 0750 root:root (only caddy validate reads
# the file as root normally); the lima user has passwordless sudo.
if sudo /usr/local/bin/caddy validate --config /etc/ai-gateway/Caddyfile \
     --adapter caddyfile >/dev/null 2>&1; then
  ok "gateway Caddyfile validates"
else
  bad "gateway Caddyfile validates (sudo caddy validate on /etc/ai-gateway/Caddyfile)"
fi

# Route smoke tests: a dummy key should reach the upstream and get 200
# (real key seeded) or 401 (key missing/rejected) — never the gateway's
# default-deny 403 and never 502. This catches path/base-URL drift.
C="$(gw_code /opencode-go/inference/go/v1/models oc_sk_sandbox_dummy)"
case "$C" in
  200|401) ok "route /opencode-go reaches OpenCode Console" ;;
  *) bad "route /opencode-go reaches OpenCode Console (got ${C:-no answer})" ;;
esac

C="$(gw_code /deepseek/v1/models sk-deepseek-sandbox-dummy)"
case "$C" in
  200|401) ok "route /deepseek reaches DeepSeek" ;;
  *) bad "route /deepseek reaches DeepSeek (got ${C:-no answer})" ;;
esac

echo "== images (flavors + shared toolchains; build first if missing) =="
# Each check: image exists + the binary answers --version. All flavors
# carry the same toolchains; toolchain binaries are probed once on the
# opencode flavor, agent CLIs on their own flavors.
check_tool() { # check_tool <label> <image> <binary> [args...]
  local label="$1" image="$2" bin="$3"; shift 3
  if ! image_exists "$image"; then bad "$label (image $image missing — run: just build)"; return; fi
  if docker run --rm --entrypoint "$bin" "$image" "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    bad "$label"
  fi
}
check_tool "ai-opencode : opencode" ai-opencode:latest opencode --version
check_tool "ai-deepseek : dsh"      ai-deepseek:latest dsh      --version
check_tool "ai-whiteboard : node"    ai-whiteboard:latest    node     --version
# whiteboard is agent-free BY DESIGN — assert it; a found CLI means a
# layering leak between stages, not a cosmetic issue.
if image_exists ai-whiteboard:latest; then
  if docker run --rm --entrypoint bash ai-whiteboard:latest \
       -c '! command -v claude && ! command -v codex && ! command -v opencode && ! command -v dsh' >/dev/null 2>&1; then
    ok "ai-whiteboard : agent-free (no claude/codex/opencode/dsh)"
  else
    bad "ai-whiteboard : contains an agent CLI — stage layering leak, check the Dockerfile"
  fi
fi
if image_exists ai-deepseek:latest; then
  if docker run --rm --entrypoint bash ai-deepseek:latest \
       -c 'test -f "$DSH_HOME/profiles/web/cordis.patch.yml"' >/dev/null 2>&1; then
    ok "ai-deepseek : baked dsh web profile present"
  else
    bad "ai-deepseek : baked dsh web profile missing"
  fi
fi
check_tool "shared: node"                    ai-opencode:latest  node  --version
check_tool "shared: tsc (typescript)"        ai-opencode:latest  tsc   --version
check_tool "shared: rustc"                   ai-opencode:latest  rustc --version
check_tool "shared: go"                      ai-opencode:latest  go    version
check_tool "shared: uv"                      ai-opencode:latest  uv    --version
# agent-git-auth with no GIT_SSH_KEY_B64 exits 0 ("nothing to install") —
# asserting both presence and the safe no-op behavior.
check_tool "shared: agent-git-auth (no-op unless opted in)" ai-whiteboard:latest agent-git-auth

echo "== sandbox semantics (one full sysbox boot — takes a few seconds) =="
if image_exists ai-opencode:latest; then
  OUT="$(docker run --rm --runtime=sysbox-runc ai-opencode:latest bash -lc '
    set -e
    # inner daemon answers
    docker info --format "{{.ServerVersion}}" >/dev/null
    # ...and is PRIVATE to this sandbox (no outer containers leak in)
    [ -z "$(docker ps -aq)" ]
    # user namespace is really in effect: inside-UID 0 maps to a non-zero
    # outside UID (typically 165536) — root inside, unprivileged on the VM
    [ "$(awk "NR==1{print \$2}" /proc/self/uid_map)" != "0" ]
    node --version >/dev/null && rustc --version >/dev/null && opencode --version >/dev/null
    # the uv-managed cpython is really there, and bare python3 points at it
    uv python find >/dev/null && python3 --version >/dev/null
    # inner daemon can start a container (best effort: the pull needs
    # network/mirror; mirror health is asserted in the VM section)
    docker run --rm hello-world >/dev/null 2>&1 || true
  ' 2>&1)"
  RC=$?
  if [ $RC -eq 0 ]; then
    ok "sysbox sandbox: inner docker + isolation + OpenCode + toolchains"
  else
    bad "sysbox sandbox boot (details below)"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  fi
else
  bad "sandbox semantics skipped — ai-opencode:latest missing"
fi

echo "== all flavors, one dir, concurrently (the suffix model) =="
# Boots the same project dir as all THREE flavors at once: separate
# compose projects (bare name vs -dsh vs -clean), disjoint
# volumes/networks, the opt-in ports window merged for both with the dsh
# override REPLACING the opencode one (!override), OS-env SANDBOX_IMAGE
# beating --env-file, one ad-hoc expose relay answering on the VM
# loopback, and the designed loud refusal of an in-window relay claim.
# This mirrors what the Justfile's compose wrapper builds for `up <p>`
# + `up <p>-dsh` (+ `up <p>-clean`, the windowless leg — see below).
SMOKE="smoke-conc-$$"
SMOKE_DIR="/mnt/projects/$SMOKE"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if ! image_exists ai-opencode:latest || ! image_exists ai-deepseek:latest \
   || ! image_exists ai-whiteboard:latest; then
  bad "concurrency smoke skipped — build all three flavors first (just build)"
else
  mkdir -p "$SMOKE_DIR"
  # The conflicting SANDBOX_IMAGE line is deliberate: proves OS env wins.
  # DSH_PORT=3099 is deliberately NOT the 3080 default: a REAL dsh project
  # may be up on the VM (e.g. the user's own) — the smoke must never claim
  # its port. Same idea as the windows below (3530s / 3540s).
  printf '%s\n' \
    'SANDBOX_IMAGE=ai-whiteboard:latest' \
    'SANDBOX_PORTS=1' \
    'PORT_BASE=3530' 'PORT_BASE_END=3539' \
    'DSH_PORT_BASE=3540' 'DSH_PORT_BASE_END=3549' \
    'DSH_PORT=3099' \
    > "$SMOKE_DIR/.sandbox.env"

  SANDBOX_IMAGE=ai-opencode:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" -f "$REPO_DIR/sandbox/compose.ports.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE" up -d >/dev/null 2>&1 \
    && ok "conc: opencode sandbox boots (project $SMOKE)" \
    || bad "conc: opencode sandbox boots (project $SMOKE)"

  SANDBOX_IMAGE=ai-deepseek:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" -f "$REPO_DIR/sandbox/compose.ports.yaml" \
    -f "$REPO_DIR/sandbox/compose.dsh.yaml" -f "$REPO_DIR/sandbox/compose.dsh.ports.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE-dsh" up -d >/dev/null 2>&1 \
    && ok "conc: dsh sandbox boots alongside (project $SMOKE-dsh)" \
    || bad "conc: dsh sandbox boots alongside (project $SMOKE-dsh)"

  # The -clean leg runs WINDOWLESS on purpose: the smoke env's single
  # PORT_BASE is already claimed by the opencode project — a second
  # claim is the designed loud failure (concurrent window projects need
  # distinct ranges; the dsh leg shows the per-flavor window instead).
  SANDBOX_IMAGE=ai-whiteboard:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE-clean" up -d >/dev/null 2>&1 \
    && ok "conc: whiteboard (-clean) boots alongside both agents" \
    || bad "conc: whiteboard (-clean) boots alongside both agents"

  if docker ps --filter name="^${SMOKE}-agent-1$" --filter status=running -q | grep -q . \
     && docker ps --filter name="^${SMOKE}-dsh-agent-1$" --filter status=running -q | grep -q . \
     && docker ps --filter name="^${SMOKE}-clean-agent-1$" --filter status=running -q | grep -q .; then
    ok "conc: all three service containers running side by side"
  else
    bad "conc: all three service containers running side by side"
  fi

  if docker volume ls --format '{{.Name}}' | grep -q "^${SMOKE}_inner-docker-data$" \
     && docker volume ls --format '{{.Name}}' | grep -q "^${SMOKE}-dsh_inner-docker-data$" \
     && docker volume ls --format '{{.Name}}' | grep -q "^${SMOKE}-dsh_dsh-home$" \
     && docker volume ls --format '{{.Name}}' | grep -q "^${SMOKE}-clean_inner-docker-data$"; then
    ok "conc: per-flavor volume namespaces (no shared docker stores)"
  else
    bad "conc: per-flavor volume namespaces (no shared docker stores)"
  fi

  CFG="$(SANDBOX_IMAGE=ai-deepseek:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" -f "$REPO_DIR/sandbox/compose.ports.yaml" \
    -f "$REPO_DIR/sandbox/compose.dsh.yaml" -f "$REPO_DIR/sandbox/compose.dsh.ports.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE-dsh" config 2>/dev/null || true)"
  if printf '%s' "$CFG" | grep -q "3540" && printf '%s' "$CFG" | grep -q "3549" \
     && ! printf '%s' "$CFG" | grep -q "3530"; then
    ok "conc: dsh !override replaces the opencode window (compose >= 2.24)"
  else
    bad "conc: dsh !override replaces the opencode window (compose >= 2.24 required?)"
  fi
  # Same env, but without the opt-in dsh ports file: UI only, no dev window.
  CFG_NOPORTS="$(SANDBOX_IMAGE=ai-deepseek:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" \
    -f "$REPO_DIR/sandbox/compose.dsh.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE-dsh" config 2>/dev/null || true)"
  if printf '%s' "$CFG_NOPORTS" | grep -q "3080" \
     && ! printf '%s' "$CFG_NOPORTS" | grep -q "3540" \
     && ! printf '%s' "$CFG_NOPORTS" | grep -q "3530"; then
    ok "conc: dsh dev window is opt-in (compose.dsh.ports.yaml only)"
  else
    bad "conc: dsh dev window leaked without SANDBOX_PORTS"
  fi
  if printf '%s' "$CFG" | grep -q "image: ai-deepseek"; then
    ok "conc: OS env SANDBOX_IMAGE beats the --env-file value"
  else
    bad "conc: OS env SANDBOX_IMAGE beats the --env-file value"
  fi

  # Relay end-to-end: a listener inside the sandbox, relayed to the VM's
  # loopback via service-name DNS. Port 3611 is OUTSIDE both windows on
  # purpose — an in-window port (3531) is claimed by the smoke project's
  # own PORT_BASE publish already; that refusal gets its own assertion
  # right after (host-docker collision semantics, by design).
  RPORT=3611
  cid="$(docker ps -q --filter name="^${SMOKE}-agent-1$" | head -1)"
  if [ -n "$cid" ]; then
    docker exec -d "$cid" python3 -m http.server $RPORT >/dev/null 2>&1
    sleep 1
    docker rm -f "${SMOKE}-expose-$RPORT" >/dev/null 2>&1 || true
    if docker run -d --rm --name "${SMOKE}-expose-$RPORT" \
         --network "${SMOKE}_default" \
         -p 127.0.0.1:$RPORT:$RPORT \
         --label ai-sandbox.relay="$SMOKE" --label ai-sandbox.target=agent:$RPORT \
         alpine/socat tcp-listen:$RPORT,fork,reuseaddr tcp:agent:$RPORT >/dev/null 2>&1; then
      if curl -sf --max-time 8 "http://127.0.0.1:$RPORT/" >/dev/null 2>&1; then
        ok "conc: expose relay serves loopback via service-name DNS"
      else
        bad "conc: expose relay answered (curl through socat + agent DNS)"
      fi
      docker rm -f "${SMOKE}-expose-$RPORT" >/dev/null 2>&1 || true
    else
      bad "conc: expose relay started (alpine/socat via the mirror?)"
    fi
    # The designed conflict: a relay claiming a port the window already
    # holds must fail loudly — never a silent remap.
    docker rm -f "${SMOKE}-expose-conflict" >/dev/null 2>&1 || true
    if docker run -d --rm --name "${SMOKE}-expose-conflict" \
         --network "${SMOKE}_default" \
         -p 127.0.0.1:3531:3531 \
         --label ai-sandbox.relay="$SMOKE" --label ai-sandbox.target=agent:3531 \
         alpine/socat tcp-listen:3531,fork,reuseaddr tcp:agent:3531 >/dev/null 2>&1; then
      docker rm -f "${SMOKE}-expose-conflict" >/dev/null 2>&1 || true
      bad "conc: in-window relay claim NOT refused (3531 sits inside the 3530-3539 window)"
    else
      ok "conc: in-window relay claim refused loudly (port already allocated)"
    fi
  else
    bad "conc: expose relay — opencode container missing"
  fi

  # The dsh web UI check proves the PUBLISH + launcher are up — any HTTP
  # status counts (DSH auth-fences bare requests: a 401/403 still proves
  # the port answers; the browser flow does the real validation).
  dsh_code=""
  dsh_i=0
  while [ "$dsh_i" -lt 12 ]; do
    dsh_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:3099/" 2>/dev/null || true)"
    case "$dsh_code" in
        ""|000) sleep 5; dsh_i=$((dsh_i + 1)) ;;
        *) break ;;
    esac
  done
  case "$dsh_code" in
      ""|000) bad "conc: dsh web UI on 127.0.0.1:3099 — no HTTP response after ~60s (last code: '${dsh_code:-none}' — boot slow? re-run verify)" ;;
      *) ok "conc: dsh web UI answers on 127.0.0.1:3099 (HTTP $dsh_code — any status proves the publish + launcher are up)" ;;
  esac

  # sweep every smoke relay by label (name-agnostic — covers any variant a
  # killed run might have left), then both projects down -v
  relay_ids="$(docker ps -aq --filter label=ai-sandbox.relay="$SMOKE" 2>/dev/null)"
  [ -n "$relay_ids" ] && docker rm -f $relay_ids >/dev/null 2>&1 || true
  SANDBOX_IMAGE=ai-opencode:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" -f "$REPO_DIR/sandbox/compose.ports.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE" down -v >/dev/null 2>&1 || true
  SANDBOX_IMAGE=ai-deepseek:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" -f "$REPO_DIR/sandbox/compose.ports.yaml" \
    -f "$REPO_DIR/sandbox/compose.dsh.yaml" -f "$REPO_DIR/sandbox/compose.dsh.ports.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE-dsh" down -v >/dev/null 2>&1 || true
  SANDBOX_IMAGE=ai-whiteboard:latest docker compose --env-file "$SMOKE_DIR/.sandbox.env" \
    -f "$REPO_DIR/sandbox/compose.sandbox.yaml" \
    --project-directory "$SMOKE_DIR" --project-name "$SMOKE-clean" down -v >/dev/null 2>&1 || true
  rm -rf "$SMOKE_DIR"
  if ! docker ps -aq --filter name="^${SMOKE}" | grep -q . && ! docker volume ls -q | grep -q "^${SMOKE}"; then
    ok "conc: teardown clean (containers, volumes, smoke dir gone)"
  else
    bad "conc: teardown — residue left behind"
  fi
fi

echo
echo "result: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
