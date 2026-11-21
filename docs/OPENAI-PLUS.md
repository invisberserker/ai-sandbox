# OpenAI Plus / ChatGPT subscription auth (design note)

Status: **not implemented.** This records the two viable ways to use a
ChatGPT Plus/Pro subscription with Codex inside the sandbox, plus the
API-key fallback, so the decision does not have to be re-derived later.

The archived shared `ai-identity` volume is the ancestor of both designs:
it proved that Codex's `CODEX_HOME` can live on a persistent volume and
be reused across projects. The difference here is scope and where the
long-lived refresh token lives.

Relevant Codex facts (verify against the pinned Codex version before
implementing):

- ChatGPT auth is stored in `$CODEX_HOME/auth.json` (`auth_mode:
  "chatgpt"`, `tokens.access_token`, `tokens.refresh_token`,
  `tokens.id_token`, `tokens.account_id`; exact fields vary by version).
- API requests go to the ChatGPT backend with
  `Authorization: Bearer <access_token>` and `chatgpt-account-id`.
- Refresh uses the OAuth token endpoint
  (`https://auth.openai.com/oauth/token` in current builds) with the
  Codex OAuth client id; refresh tokens can rotate.
- `codex login --with-access-token` exists, which is useful for
  bootstrapping but **not** a substitute for a refresh loop.

## Version A — scoped shared `codex-identity` volume

The pragmatic version: one external volume, opt-in per Codex project,
one interactive login. This is the archived `ai-identity` idea without
Claude and without mounting the volume into every sandbox.

### Topology

```
throwaway sandbox             VM root namespace                 Codex sandbox
codex login (once)  ──►  external volume codex-identity  ──►  CODEX_HOME=/root/.codex-identity
                         (real auth.json, refresh token)        Codex CLI reads it
```

### Implementation sketch

1. Create an external volume (survives `compose down -v`):

   ```bash
   limactl shell ai-box -- docker volume create codex-identity
   ```

2. Use a compose override, analogous to `sandbox/compose.dsh.yaml`:

   ```yaml
   services:
     agent:
       environment:
         - CODEX_HOME=/root/.codex-identity
       volumes:
         - type: volume
           source: codex-identity
           target: /root/.codex-identity

   volumes:
     codex-identity:
       external: true
   ```

   Run Codex projects through a `just codex-up`/`codex-shell` wrapper that
   adds this file. Only opted-in projects mount the volume.

3. Log in once in a throwaway sandbox:

   ```bash
   docker run --rm -it --runtime=sysbox-runc \
     -v codex-identity:/root/.codex-identity \
     -e CODEX_HOME=/root/.codex-identity \
     ai-opencode:latest \
     bash -lc 'npx -y @openai/codex login'
   ```

   (Codex is not baked into the current images; re-add a thin Codex stage
   if you want it permanently.)

4. Reset the login with `docker volume rm codex-identity` after stopping
   the containers. Revoke the session in the ChatGPT/OpenAI account
   settings if the token may have leaked.

### Security properties

- Real refresh token is inside every sandbox that mounts the volume.
  Any prompt-injected agent can read it.
- Multiple sandboxes share one auth file. Codex's refresh may rotate the
  token; concurrent refreshes can race and one sandbox can invalidate
  another's session.
- The gateway cannot help: Codex needs to perform the OAuth refresh
  itself, and that needs the refresh token.
- Provider usage limits and account-sharing/abuse policies still apply.
  Keep concurrency low; one stable VM IP helps but is not a guarantee.
- Blast radius is reduced compared with the old broad `ai-identity`
  because the volume is provider-specific and mounted only where needed.

### When to choose it

Choose A if you want the smallest amount of machinery, run one or two
Codex sessions at a time, and accept that the refresh token is inside
the sandbox. It is the pragmatic fallback.

## Version B — refresh-aware token sidecar (preferred)

The sidecar is a separate credential-refreshing process outside the
sandboxes. It holds the real refresh token root-only on the VM and
publishes only a short-lived access token to a volume the sandboxes can
read. Think of it as a Kubernetes-style sidecar that owns the refresh
cycle, except it runs on the VM/outer Docker, not inside the workload.

### Topology

```
                     VM root namespace
  /etc/ai-identity/openai/auth.json (root:root 0600)
              │  real refresh token
              ▼
     codex-auth-sidecar  ── refresh every N minutes ──► auth.openai.com/oauth/token
              │  writes atomically
              ▼
     codex-identity volume  auth.json (sidecar path /publish/auth.json)
              │  access_token + account_id only
              ▼
     sandbox: CODEX_HOME=/root/.codex-identity
              Codex CLI; never sees refresh_token
```

### Components

1. **Secret store** — `/etc/ai-identity/openai/auth.json`, root:root
   0600. Created once from an interactive Codex login. Never mounted
   into a sandbox. Contains the rotating refresh token. Run **one
   sidecar per OpenAI account/workspace**; don't mix identities in one
   publish file. A second workspace gets a second secret store and a
   second volume.

2. **Sidecar** — a small service (systemd on the VM, or an outer Docker
   container) that:
   - reads the secret store;
   - parses the access token expiry (JWT `exp`, or a conservative
     refresh interval if the token is opaque);
   - refreshes before expiry using the OAuth token endpoint and the
     pinned Codex client id;
   - writes the rotated refresh token back to the secret store
     atomically;
   - writes a **publish** `auth.json` to the shared volume:
     `auth_mode: "chatgpt"`, `tokens.access_token`,
     `tokens.account_id`, and other non-secret fields the CLI needs.
     The publish file contains **no real refresh token** (omit it, or use
     a clearly fake placeholder if the CLI insists on the field);
   - sleeps until the next refresh window.

3. **Sandbox volume** — external `codex-identity` volume mounted at
   `CODEX_HOME=/root/.codex-identity` only for opted-in Codex projects.
   Sandboxes are readers; the sidecar is the only writer.

### Bootstrap once

Log in interactively in a throwaway sandbox (or on the Mac) with a
temporary `CODEX_HOME`, then copy the resulting `auth.json` to the VM
secret store and delete the temporary copy:

```bash
# inside a one-off sandbox
codex login
cat "$CODEX_HOME/auth.json"   # copy this to the Mac temporarily

# on the Mac: install it root-only on the VM
limactl shell ai-box -- sudo install -d -m 0750 /etc/ai-identity/openai
limactl shell ai-box -- sudo tee /etc/ai-identity/openai/auth.json >/dev/null
# paste the JSON, then:
limactl shell ai-box -- sudo chmod 0600 /etc/ai-identity/openai/auth.json
```

Never leave that copy on the Mac or in a project directory. The sidecar
takes over refresh from there.

### Refresh loop (pseudocode)

```text
every 10 minutes, and on start:
  secret = read_json(/secret/auth.json)
  if access_token_expiry(secret) > now + 24h:
      publish(secret)
      continue
  response = POST https://auth.openai.com/oauth/token
      grant_type=refresh_token
      refresh_token=secret.tokens.refresh_token
      client_id=<pinned Codex OAuth client id>
  if response.ok:
      atomic_write(/secret/auth.json, merged(secret, response.tokens))
      publish(merged(secret, response.tokens))
  else:
      log; do not publish a broken file; alert
```

`publish` writes a temp file in the publish directory, `fsync`s it, and
renames it over `auth.json` so readers never see a partial file. Keep the
publish file world-readable (0644) or otherwise readable by the sandbox's
mapped UID; the directory should be 0755. The secret store stays 0600
root.

### Deployment sketch

Either a systemd service on the VM (like the gateway) or an outer Docker
container (like the registry mirror). The container form is:

```bash
docker run -d --name codex-auth-sidecar --restart=unless-stopped \
  -v codex-identity:/publish \
  -v /etc/ai-identity/openai:/secret:ro \
  -e CODEX_AUTH_REFRESH_URL=https://auth.openai.com/oauth/token \
  -e CODEX_AUTH_CLIENT_ID=<pinned-codex-client-id> \
  -e CODEX_AUTH_REFRESH_MARGIN=24h \
  ai-codex-auth-sidecar:latest
```

The sidecar image is a tiny script/binary that implements the loop above.
It runs **outside** sysbox; sandboxes only see `/publish/auth.json`. Harden
it like the gateway: root-only secret mount, `LimitCORE=0`, no new
privileges, and no shell tools beyond what the refresh script needs.

If you prefer systemd, the same binary can run as a hardened unit with
`EnvironmentFile=/etc/ai-identity/openai/sidecar.env`; the only extra
requirement is write access to the `codex-identity` volume's host path,
which is easier to express with the container form.

### Why the sidecar is better

- The long-lived refresh token never enters a sandbox.
- A single writer serializes refresh; no concurrent-refresh race.
- A leaked sandbox token is a short-lived access token, not a refresh
  token that can mint unlimited sessions.
- Multiple projects can share the published access token, but revoking
  one leaked access token does not require re-running interactive login
  (the sidecar refreshes on schedule).

### Risks and validation items

- **Codex may cache the access token in memory.** The publish-file
  broker works if Codex re-reads `auth.json` when its token expires. If a
  long-running Codex process caches the token and does not re-read, the
  session will eventually 401 until restarted. Test this before
  committing. If it fails, the next step is a request-level proxy (below)
  or periodic session restart.
- **Auth schema changes.** `auth.json` fields and the OAuth client id
  are Codex-version-specific. Pin the Codex version and re-test when
  bumping.
- **Refresh-token rotation.** The sidecar must persist the new refresh
  token before discarding the old one. If it crashes between the refresh
  response and the atomic write, the old refresh token may be invalid;
  keep the response in a temp file and recover on start.
- **Sidecar compromise = refresh-token compromise.** The sidecar runs
  root on the VM, like the gateway. Harden the unit/container and keep
  the secret store root-only.
- **Provider policy.** One subscription used by multiple concurrent
  projects is still one account used heavily. Keep concurrency sane and
  respect OpenAI's terms.

### Variant B2 — request proxy instead of publish file

If the publish-file broker proves unreliable because Codex caches the
token, the sidecar can instead be a reverse proxy that injects the
current access token into every request. This is closer to the
Kubernetes sidecar model:

- point Codex's ChatGPT backend/base URL at the sidecar (only if the
  pinned Codex version supports a supported base-URL override; the
  `chatgpt_base_url` setting covers the login flow, not necessarily every
  API destination);
- the sidecar holds the refresh token, refreshes centrally, and injects
  `Authorization: Bearer <access_token>` plus `chatgpt-account-id` on
  each request;
- nothing credential-like is written into the sandbox.

This avoids token caching and refresh races completely, but requires
either a supported Codex endpoint override or a TLS-level interception
for hardcoded ChatGPT hosts. It is more coupling to Codex's network
layout; only take this path if B1 fails validation.

### Validation checklist for B1

Before trusting B1, prove:

1. The publish `auth.json` has no real refresh token.
2. `codex exec "say ok"` works with only the published access token.
3. Force a refresh (temporarily set the margin high so the sidecar
   refreshes immediately), then confirm the running sandbox still works.
4. Start a long-running Codex session across a refresh window and confirm
   it does not 401. If it does, Codex cached the old access token; move to
   B2 or restart sessions after refresh.
5. Restart the sidecar with an already-rotated refresh token; it must
   recover the current secret, not overwrite it with the old one.

## Version C — API key through the gateway

If avoiding real credentials in sandboxes matters more than subscription
pricing, use an OpenAI API key through a gateway route, exactly like
`/opencode-go`/`/deepseek`:

```caddyfile
handle_path /openai/* {
    reverse_proxy https://api.openai.com {
        header_up Host api.openai.com
        header_up Authorization "Bearer {env.REAL_OPENAI_API_KEY}"
    }
}
```

The sandbox holds a dummy `OPENAI_API_KEY`. This is the only design with
no real credential in any sandbox, but it is billed per token instead of
against the Plus subscription. Keep Plus for interactive use on the Mac,
or for a host-side Codex if that fits the task.

## Comparison

| | A: shared volume | B1: token broker sidecar | B2: request proxy | C: API key gateway |
| --- | --- | --- | --- | --- |
| Real refresh token in sandbox | yes | no | no | no |
| Sandbox credential | refresh + access | short-lived access | none / short-lived | dummy |
| Refresh race | possible | serialized | serialized | none |
| Long-running sessions | CLI handles refresh | depends on re-read | works | works |
| Implementation effort | low | medium | high | low |
| Cost model | Plus subscription | Plus subscription | Plus subscription | API billing |

## Recommendation

Start with **B1** if you are willing to own a small sidecar; it matches
the architecture you already have (gateway-like root-owned credential
process + dummy/short-lived credentials in sandboxes) and removes the
worst part of the old identity volume. Validate Codex's token re-read
behavior first. Fall back to **A** if you want the least machinery and
accept the risk, or **C** if you want no real credential in any sandbox.

Do not reuse the broad `ai-identity` volume. One provider per volume,
one writer for the refresh cycle, and only opt-in projects.
