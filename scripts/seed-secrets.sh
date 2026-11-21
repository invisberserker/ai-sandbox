#!/usr/bin/env bash
# =============================================================================
# seed-secrets.sh — install real API keys onto the VM's gateway (idempotent)
# =============================================================================
# Runs (a) automatically during VM provisioning / rebuilds, and (b) manually
# via `just seed-secrets` after you edit the source file on the Mac:
#
#     ~/.ai-secrets/ai-gateway.env     (on the Mac, 0600, outside any repo)
#          → shared READ-ONLY into the VM as /mnt/secrets →
#          → copied to → /etc/ai-gateway/secrets.env  (on the VM, root:root 0600)
#
# Why the indirection: the Mac-side file survives `just vm-rebuild` (and is
# the only copy you back up); the VM copy is disposable. The read-only share
# means a compromised VM can read the keys (the gateway must) but can never
# tamper with the Mac's only copy. Sandboxes can never see either file —
# they only reach the gateway's HTTP port, and per-project bind mounts
# expose project subdirectories only.
#
# Runs as root INSIDE the VM.
# =============================================================================
set -euo pipefail

SRC="/mnt/secrets/ai-gateway.env"
DST="/etc/ai-gateway/secrets.env"

install -d -m 0750 /etc/ai-gateway

if [ ! -f "$SRC" ]; then
    # First boot before the user created the secrets file: write a commented
    # placeholder so the gateway starts. Routes inject EMPTY keys until real
    # ones are seeded — provider requests fail fast with 401, which is the
    # correct loud behavior for a missing key, not a leak.
    if [ ! -f "$DST" ]; then
        cat > "$DST" <<'EOF'
# Placeholder — see ~/ai-projects/ai-sandbox/secrets/ai-gateway.env.example
# Create ~/.ai-secrets/ai-gateway.env on the Mac with real keys,
# then run: just seed-secrets
EOF
        chmod 0600 "$DST"
    fi
    echo "[seed-secrets] no source file at $SRC — placeholder in place" >&2
    exit 0
fi

# Sanity: refuse a world-readable source (it lives on a shared folder).
PERM="$(stat -c '%a' "$SRC")"
if [ "$PERM" != "600" ]; then
    echo "[seed-secrets] WARNING: $SRC is mode $PERM (wanted 600) — copying with 0600; run 'chmod 600' on the Mac side" >&2
fi

install -m 0600 -o root -g root "$SRC" "$DST"

# Restart the gateway so Caddy re-reads its environment. Tolerate a not-yet-
# installed unit (provisioning ordering) — provisioning restarts it anyway.
RESTARTED=""
if systemctl list-unit-files 2>/dev/null | grep -q '^ai-gateway.service'; then
    systemctl restart ai-gateway
    RESTARTED="; gateway restarted"
fi

COUNT="$(grep -c '^REAL_[A-Z_]*=' "$DST" || true)"
echo "[seed-secrets] installed ${COUNT} real key(s)${RESTARTED}"
