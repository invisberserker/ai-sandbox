#!/usr/bin/env bash
# =============================================================================
# go-keepalive.sh — the OpenCode Go "dad joke" ping (runs INSIDE a sandbox)
# =============================================================================
# Invoked by `just activate` (Justfile): it scaffolds the `go-keepalive`
# burner project, copies this file into the project dir (bind-mounted at
# /workspace inside the sandbox), runs it in a one-off container, then
# purges the volumes and deletes the dir.
#
# The request rides the credential gateway like every OpenCode call
# (gateway/Caddyfile): the Bearer below is the format-valid DUMMY the
# compose file sets as OPENCODE_API_KEY — worthless if exfiltrated, and
# swapped for the real Go key in transit. A 200 reply means the round
# trip reached OpenCode Console, i.e. the plan's 5-hour rolling window
# is now live. The dad joke is the payload: cheap, harmless, and
# human-readable proof in the output.
#
# The curl is a ONE-LINER by design — this is also the line to paste at
# an interactive `just shell <project>` prompt:
#
#   curl -s -H 'Authorization: Bearer oc_sk_sandbox_dummy' -H "x-opencode-session: $(cat /proc/sys/kernel/random/uuid)" -H 'content-type: application/json' -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"tell me a dad joke"}],"max_tokens":100}' http://host.docker.internal:4000/opencode-go/inference/go/v1/chat/completions
#
# Not runnable on the Mac or the VM directly: host.docker.internal only
# resolves inside containers. deepseek-v4.1-flash is the Go plan's
# CHEAPEST model — ~43k requests/5h on Go, the most generous line in the
# plan's allowance table (https://opencode.ai/console/go) — deliberate:
# the ping only needs to reach the endpoint, not to be smart. NAME vs ID:
# the TUI and console display "DeepSeek V4.1 Flash 1017", but the 1017
# checkpoint suffix is DISPLAY-ONLY — the wire id is deepseek-v4.1-flash
# (upstream 400s "isn't included in OpenCode Go" on anything else). It
# is a DeepSeek MODEL on the OPENCODE GO route — do not "fix" it to
# /deepseek, which would spend the separate DeepSeek key and never touch
# the Go window. Status decode:
#   200 = window poked · 400 = payload rejected (model id drifted?) ·
#   401 = real key missing/rejected → just seed-secrets · 403 = route
#   prefix wrong (default-deny) · 404/502 = path/base-URL drift or
#   upstream down · no reply = gateway or VM down (just vm-shell →
#   systemctl status ai-gateway).
# =============================================================================
set -euo pipefail

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# OpenCode Go refuses sessionless requests (400 MissingSessionID):
# x-opencode-session is its prompt-cache routing key, and the gateway
# passes it through untouched — the curl itself must send one. Fresh
# UUID per run, same as the TUI sends per session.
sid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"

# The one-liner, with -o/-w bolted on to keep the reply and its status:
code="$(curl -sS -o "$body" -w '%{http_code}' -H 'Authorization: Bearer oc_sk_sandbox_dummy' -H "x-opencode-session: $sid" -H 'content-type: application/json' -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"tell me a dad joke"}],"max_tokens":100}' http://host.docker.internal:4000/opencode-go/inference/go/v1/chat/completions)" || code=000

case "$code" in
  200)
    printf 'opencode go answered (HTTP 200) — the 5h rolling window is live:\n\n  '
    jq -r '.choices[0].message.content' "$body" 2>/dev/null || cat "$body"
    printf '\n'
    exit 0
    ;;
  401)
    echo "HTTP 401: the route works but the REAL key is missing/rejected — just seed-secrets" >&2
    ;;
  400)
    echo "HTTP 400: upstream rejected the request — model id drifted (check the TUI's /models picker) or the payload contract changed" >&2
    ;;
  403)
    echo "HTTP 403: no gateway route matched (default-deny) — base URL lost its /opencode-go prefix?" >&2
    ;;
  404|502)
    echo "HTTP $code: path/base-URL drift or upstream unreachable — docs/RUNBOOK.md" >&2
    ;;
  000)
    echo "no reply: gateway down on the VM? (just vm-shell → systemctl status ai-gateway)" >&2
    ;;
  *)
    echo "HTTP $code (expected 200) — decode table: docs/RUNBOOK.md" >&2
    ;;
esac
echo "response body:" >&2
sed 's/^/  /' "$body" >&2 || true
echo >&2
exit 1
