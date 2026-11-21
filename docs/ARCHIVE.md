# Archived designs

Designs that were implemented and removed, kept here as rationale and
restore notes. They are **not** active. Do not wire them back in without
reading the costs section.

## Shared subscription OAuth identity (Claude Code / Codex)

### Why it existed

API billing for frontier models is expensive; consumer subscription plans
(Claude Pro/Max, ChatGPT Plus/Pro) are much cheaper for individual use.
Both CLIs support interactive OAuth login, which stores a long-lived
refresh token in their config directory. The shared identity volume let you
log in **once**, in any sandbox, and reuse that login across every project.

### How it worked

- An external Docker volume `ai-identity`, mounted at
  `/root/.ai-identity` by every sandbox.
- Image ENV:
  ```dockerfile
  ENV CLAUDE_CONFIG_DIR=/root/.ai-identity/claude \
      CODEX_HOME=/root/.ai-identity/codex
  ```
- The image seeded a gateway-wired Codex config into the volume:
  ```dockerfile
  COPY rootfs/root/.codex/config.toml /root/.ai-identity/codex/config.toml
  ```
- Compose declared the volume external, so `just purge` (`compose down -v`)
  could never remove it. The Justfile created it idempotently before every
  compose call.
- `just identity-reset` was the deliberate deletion lever. It removed the
  volume; every project re-prompted login on next entry, and the Codex
  config re-seeded from the image.
- Logins survived container resets because the config directories were on
  the persistent shared volume.

### Costs / why it was removed

1. **The real refresh token lived inside the sandbox.** Any prompt-injected
   agent running as root could read it. The credential gateway cannot
   protect it because the CLI itself needs the token to talk to the
   provider. This is the one place where "keys never enter a sandbox" was
   false.
2. **Concurrent sandboxes shared one auth file.** OAuth refresh can rotate
   tokens; two sandboxes refreshing at once can race, and last-write-wins
   can leave one with a stale refresh token and intermittent 401s.
3. **Provider policy/abuse exposure.** One consumer account used by many
   concurrent projects/sessions can look like account sharing or a token
   relay. A single stable VM IP helps, but does not remove the risk.
4. **Revocation is two-step.** Deleting the volume only removes the local
   copy; you must also log out sessions in the provider's account settings.

For a single user with low concurrency it is a pragmatic convenience, but
it is not the default security posture of this stack.

### Preferred paths if restored

- **Claude subscription:** use `claude setup-token` on the Mac instead of
  `/login` inside a sandbox. The resulting ~1-year token goes into
  `~/.ai-secrets/ai-gateway.env` as
  `REAL_ANTHROPIC_OAUTH_TOKEN`, and the sandbox holds only a dummy Bearer.
  A gateway route can inject it:
  ```caddyfile
  handle_path /anthropic-oauth/* {
      reverse_proxy https://api.anthropic.com {
          header_up Host api.anthropic.com
          header_up Authorization "Bearer {env.REAL_ANTHROPIC_OAUTH_TOKEN}"
          header_up -x-api-key
          header_up +anthropic-beta "oauth-2025-04-20"
      }
  }
  ```
  This never puts a real token inside a sandbox, but supports model
  requests only (not every `/login`-gated feature) and needs manual yearly
  rotation.
- **Codex / ChatGPT subscription:** the clean design is a refresh-aware
  credential sidecar on the VM that holds the refresh token and hands
  short-lived access tokens to sandboxes. The full design, implementation
  sketch, and fallback are in [OPENAI-PLUS.md](OPENAI-PLUS.md).

### If you later add OpenAI Plus / ChatGPT subscription

See [OPENAI-PLUS.md](OPENAI-PLUS.md) for the full designs and trade-offs:

- **A — scoped `codex-identity` volume:** the archived idea narrowed to
  one provider, opt-in projects, one interactive login. Simple; the
  refresh token is inside those sandboxes.
- **B — refresh-aware token sidecar:** the preferred design. A root-owned
  sidecar on the VM owns the refresh token and publishes only short-lived
  access tokens to the volume; one writer, no refresh race.
- **C — API key through the gateway:** the only design with no real
  credential in any sandbox, at API-billing cost.

### Restore notes

If you decide to bring the shared identity back:

1. Re-add the `ai-identity` external volume to `sandbox/compose.sandbox.yaml`
   and the Justfile's `docker volume create ai-identity` step.
2. Re-add `CLAUDE_CONFIG_DIR` / `CODEX_HOME` image ENVs and the Codex seed
   COPY (or an equivalent config).
3. Re-add the `identity-reset` recipe and document the revocation steps.
4. Keep the costs above in `docs/SECURITY.md`; do not silently present the
   sandbox as key-isolated when this volume is active.

### Old Codex config (reference)

```toml
model = "deepseek-chat"
model_provider = "deepseek"

[model_providers.deepseek]
name = "DeepSeek (via sandbox gateway)"
base_url = "http://host.docker.internal:4000/deepseek"
env_key = "DEEPSEEK_API_KEY"
wire_api = "chat"
```

This file used to live at `images/rootfs/root/.codex/config.toml` and was
also copied into the shared identity volume as the first-login seed.
