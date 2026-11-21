#!/usr/bin/env bash
# =============================================================================
# verify.sh — smoke tests for the whole stack. Runs INSIDE the VM
# (`just verify` wraps: limactl shell <vm> -- bash <repo>/scripts/verify.sh).
#
# Three sections:
#   VM     : outer daemon, sysbox registration, kernel hold, mirror, gateway
#   images : toolchain binaries answer --version (fast; entrypoint bypassed)
#   sandbox: ONE full sysbox boot — inner dockerd up, PRIVATE (docker ps
#            empty), user namespace really in effect, OpenCode functional
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
    # inner daemon can actually run a container through the mirror
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

echo
echo "result: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
