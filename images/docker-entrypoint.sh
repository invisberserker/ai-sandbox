#!/usr/bin/env bash
# =============================================================================
# docker-entrypoint.sh — inner dockerd supervisor for ai-sandbox images
# =============================================================================
# Runs as PID 1 inside sysbox sandboxes. Two jobs:
#
#   1. Bring up the sandbox's PRIVATE inner dockerd, so the agent has real
#      docker with natural localhost semantics (`docker compose up -d
#      postgres` → localhost:5432 works, dies with the sandbox, invisible to
#      other projects).
#
#   2. SUPERVISE it. /var/lib/docker inside a sandbox is a PERSISTENT named
#      volume. A naive `exec "$@"` entrypoint makes the session PID 1; on
#      `docker stop` the inner dockerd gets SIGKILLed after the grace period
#      — mid-write, on a persistent volume — which is how image stores get
#      corrupted and sandboxes start failing "mysteriously". This script
#      forwards stop signals to the session, then shuts dockerd down cleanly.
#
# Debug knobs (set via compose env or docker run -e):
#   SANDBOX_DEBUG=1        print docker version at boot + dockerd log tail
#                          on exit
#   SANDBOX_DNS=<ip>       override the inner daemon's embedded-DNS upstream
#   SANDBOX_NO_MIRROR=1    don't point the inner daemon at the VM registry
#                          mirror (for running images outside this VM)
#   SANDBOX_MIRROR_HOST=h  override mirror host (default host.docker.internal)
#   SANDBOX_NO_DOCKERD=1   don't start the inner dockerd at all — the
#                          fallback profile (runtime: runc + outer docker
#                          socket mount) sets this. The session is still
#                          supervised; `docker` talks to the OUTER daemon.
#                          Also skips the stale-socket cleanup, which would
#                          try to rm the bind-mounted outer socket (EBUSY
#                          under set -e = instant container death).
# =============================================================================
set -Eeuo pipefail

log() { printf '[sandbox-init] %s\n' "$*" >&2; }

# --- 1. Clear stale state from any previous unclean run -----------------------
# Pid/socket files live in the container's ephemeral layer, but leftovers in
# image layers or volume state can wedge dockerd on boot. SKIPPED under
# SANDBOX_NO_DOCKERD: on the fallback profile that path is a bind-mounted
# OUTER socket, and rm'ing a mountpoint is EBUSY — fatal under set -e.
if [ -z "${SANDBOX_NO_DOCKERD:-}" ]; then
  rm -f /var/run/docker.pid /var/run/docker.sock \
        /run/docker.pid /run/docker.sock \
        /run/containerd/containerd.pid
fi

# --- 2. Build-cache directories (named volume at /var/cache/build-targets) ----
mkdir -p "${CARGO_TARGET_DIR:-/var/cache/build-targets/cargo}" \
         "${GOCACHE:-/var/cache/build-targets/go-build}" \
         "${GOMODCACHE:-/var/cache/build-targets/go-mod}" \
         "${npm_config_cache:-/var/cache/build-targets/npm}" \
         "${UV_CACHE_DIR:-/var/cache/build-targets/uv}"

# --- 3. Inner dockerd flags (skipped entirely under SANDBOX_NO_DOCKERD) -------
# DNS: outer compose gives this sandbox resolv.conf 127.0.0.11 (docker's
# embedded DNS). The inner daemon REFUSES 127.x upstreams and would silently
# fall back to 8.8.8.8 — surprise egress. Instead use the sandbox's default
# gateway (the VM bridge, which forwards to the VM's systemd-resolved),
# unless SANDBOX_DNS overrides.
if [ -z "${SANDBOX_NO_DOCKERD:-}" ]; then
  HOST_GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}' || true)"
  INNER_DNS="${SANDBOX_DNS:-${HOST_GW:-1.1.1.1}}"

  # Registry mirror: the VM's pull-through cache (vm/ai-box.yaml step 5) so
  # the Nth sandbox pulling postgres:16 is a LAN-speed operation.
  # NOTE the matching --insecure-registry: the mirror speaks plain HTTP and,
  # seen from inside the sandbox, is NOT on loopback (dockerd only implies
  # insecure for 127.x) — without the flag every pull through the mirror
  # fails TLS negotiation.
  MIRROR_ARGS=()
  if [ -z "${SANDBOX_NO_MIRROR:-}" ]; then
    MIRROR_HOST="${SANDBOX_MIRROR_HOST:-host.docker.internal}"
    MIRROR_ARGS=(--registry-mirror "http://${MIRROR_HOST}:5000"
                 --insecure-registry "${MIRROR_HOST}:5000")
    log "using registry mirror http://${MIRROR_HOST}:5000"
  fi

  log "starting inner dockerd (dns=${INNER_DNS})"
  dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver=overlay2 \
    --dns="${INNER_DNS}" \
    --ip6tables=false \
    "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
    >/var/log/dockerd.log 2>&1 &
  DOCKERD_PID=$!

  # ip6tables=false: dual-stack NAT setup under user namespaces is flaky on
  # several kernel/nft combinations; IPv4-only NAT is the boring, reliable
  # choice for a dev sandbox. Revisit only with a concrete need.

  # --- 4. Readiness: fail LOUD (with logs), never by hanging ---------------------
  READY=false
  for _ in $(seq 1 240); do               # up to 60s; cold volume mounts can be slow
    if docker info >/dev/null 2>&1; then READY=true; break; fi
    if ! kill -0 "${DOCKERD_PID}" 2>/dev/null; then
      log "ERROR: inner dockerd crashed on startup. Log tail:"
      tail -n 50 /var/log/dockerd.log >&2 || true
      exit 1
    fi
    sleep 0.25
  done
  if [ "${READY}" != true ]; then
    log "ERROR: timed out waiting for inner dockerd. Log tail:"
    tail -n 50 /var/log/dockerd.log >&2 || true
    exit 1
  fi
  log "inner docker ready ($(docker --version 2>/dev/null || true))"
else
  log "SANDBOX_NO_DOCKERD set — inner dockerd skipped; docker talks to the OUTER daemon"
fi

if [ "${SANDBOX_DEBUG:-}" = "1" ]; then
  docker version || true
fi

# --- 5. Run the session (shell / agent CLI / script) and supervise ----------------
# The session needs the REAL stdin, but a non-interactive shell points
# background jobs at /dev/null (instant EOF — the container used to die
# right after "inner docker ready"). Save fd0 and hand it over explicitly.
# No `set -m`: job control would put the session in its OWN process
# group, and on the container's tty a non-foreground group that reads
# gets SIGTTIN (exit 128+21 = 149).
exec 3<&0
shutdown() {
  # Called on SIGTERM/SIGINT (docker stop, Ctrl-C) and on session exit.
  trap - TERM INT
  # Session first, with SIGHUP: an interactive bash on the compose PTY
  # (tty: true → `just up`) IGNORES SIGTERM — a TERM here hangs the stop
  # until docker's grace-period SIGKILL. HUP is honored and propagates to
  # the session's jobs; escalate to KILL if it lingers.
  kill -HUP "${CMD_PID:-0}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "${CMD_PID:-0}" 2>/dev/null || break
    sleep 0.25
  done
  kill -KILL "${CMD_PID:-0}" 2>/dev/null || true
  wait "${CMD_PID:-0}" 2>/dev/null || true
  # Inner dockerd: graceful TERM (a daemon honors it), bounded flush,
  # then KILL. Under SANDBOX_NO_DOCKERD there is nothing to flush.
  if [ -n "${DOCKERD_PID:-}" ]; then
    kill -TERM "${DOCKERD_PID}" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "${DOCKERD_PID}" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "${DOCKERD_PID}" 2>/dev/null || true
    wait "${DOCKERD_PID}" 2>/dev/null || true
  fi
  if [ "${SANDBOX_DEBUG:-}" = "1" ]; then
    log "dockerd log tail:"; tail -n 20 /var/log/dockerd.log >&2 || true
  fi
}
trap shutdown TERM INT

"$@" <&3 &
CMD_PID=$!
EXIT=0
wait "${CMD_PID}" || EXIT=$?
shutdown
exit "${EXIT}"
