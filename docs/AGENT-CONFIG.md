# Agent CLI configuration

How the two agent flavors reach their providers through the credential
gateway. The gateway is **protocol-blind**: it strips a route prefix,
forwards the rest of the path to one fixed upstream, and replaces the dummy
`Authorization` value with the real key. It does not parse model ids or
translate OpenAI/Anthropic/Gemini payloads.

For gateway-routed providers, all keys inside sandboxes are format-valid
dummies. Real keys live only in `/etc/ai-gateway/secrets.env` on the VM,
seeded from `~/.ai-secrets/ai-gateway.env` on the Mac (shared read-only
into the VM). Direct BYOK (see below) is the explicit exception: those
real keys live in the sandbox.

## Gateway routes

| Sandbox base URL | Upstream origin + native path | Auth swapped in |
| --- | --- | --- |
| `http://host.docker.internal:4000/opencode-go/inference/go/v1` | `https://opencode.ai/inference/go/v1` | `Authorization: Bearer REAL_OPENCODE_API_KEY` |
| `http://host.docker.internal:4000/deepseek/v1` | `https://api.deepseek.com/v1` | `Authorization: Bearer REAL_DEEPSEEK_API_KEY` |

The path after the route prefix is forwarded unchanged. That is why one
`/opencode-go` route covers every OpenCode Go model and every API family
(OpenAI Chat, OpenAI Responses, Anthropic Messages, Gemini): the TUI owns
the protocol choice; Console owns the translation. For the same reason —
one route per **upstream**, not per harness — a single `/deepseek` route
serves both consumers: the dsh web profile and the OpenCode flavor's
catalog `deepseek` override.

A nested container started by the sandbox's inner Docker cannot rely on
`host.docker.internal`: the name only resolves if the inner daemon adds it
(compose `extra_hosts: host-gateway`), and there `host-gateway` points at
the inner bridge, not the VM. Use the VM's docker0 address in nested
containers instead — `ip -4 addr show dev docker0` on the VM (it is not
always 172.17.0.1; the daemon allocates the default bridge wherever it
fits).

## Flavor: opencode (`ai-opencode`)

Default provider: **OpenCode Go**, via the gateway. **DeepSeek
official** is wired through the same pattern (see
[DeepSeek official via the gateway](#deepseek-official-via-the-gateway)
below). The image installs OpenCode **v2** (`@opencode/cli` on npm) and
the baked config uses the **v2 schema** — `providers`, plural, with
`settings.baseURL`. The v1 format (singular `provider` + `options.*`) is
silently ignored by v2, so don't paste old configs:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "opencode-go": {
      "settings": {
        "baseURL": "http://host.docker.internal:4000/opencode-go/inference/go/v1"
      }
    },
    "deepseek": {
      "settings": {
        "baseURL": "http://host.docker.internal:4000/deepseek/v1"
      }
    }
  },
  "model": "opencode-go/kimi-k3"
}
```

That is the "endpoint override" pattern from the v2 providers docs: each
catalog provider keeps its package, models and connection; only its base
URL is pointed at the gateway. The credential comes from the provider's
standard environment variable — compose sets `OPENCODE_API_KEY` (and the
`OPENCODE_GO_API_KEY` alias) plus `DEEPSEEK_API_KEY` to dummies, so the
env connections are active with no key material in the config file.

Use `/models` in the TUI to pick any Go model — or any catalog DeepSeek
model, which rides the `/deepseek` route (below).

The config lives under `/root/.config/opencode/` on the `home-config`
volume. Docker seeds a fresh project volume with the image copy on first
mount; later edits persist. If you change the baked file, existing
projects keep their old copy — edit it in the project or purge the
volume. That migration note is doubly true across the v1→v2 schema
change: a pre-v2 volume config (singular `provider`) is silently ignored
by v2, so re-seed or hand-edit it.

### DeepSeek official via the gateway

The `deepseek` entry in the baked config above is the same endpoint
override aimed at a second upstream: the catalog `deepseek` provider —
the one `/models` lists as **DeepSeek** — points at the same `/deepseek`
route the dsh flavor uses. Routes are per-upstream, not per-harness, so
this needs **no new Caddy block, no new secret, no gateway reload**: the
route and `REAL_DEEPSEEK_API_KEY` already exist for dsh.

The catalog provider keeps its package, its model list (current ids
`deepseek-flash`, `deepseek-v4-pro`, ...) and its `DEEPSEEK_API_KEY`
connection — compose sets that variable to the dummy in every flavor.
Picking a DeepSeek model in `/models` then works: the TUI sends
`Bearer sk-deepseek-sandbox-dummy` to `/deepseek/v1/chat/completions`,
and the gateway swaps in `REAL_DEEPSEEK_API_KEY` in transit.

Without the override, the catalog provider sends the dummy straight to
`https://api.deepseek.com` — the failure mode is DeepSeek's
`Authentication Fails, Your api key: ****ummy is invalid`. The tempting
in-TUI fix, `/connect` with your real DeepSeek key, is the anti-pattern:
it stores the real key inside the sandbox (`/root/.local` auth store),
where a prompt-injected agent can exfiltrate it. The endpoint override
is the fix that keeps the key on the VM. (Direct BYOK remains the right
escape hatch only for providers that cannot use a custom base URL.)

Sandboxes created before this override was baked keep their old
`opencode.json` on the `home-config` volume — hand-edit
`/root/.config/opencode/opencode.json` inside them to add the
`deepseek` block, or `just purge <project>` to re-seed from the image.

### Gateway-isolated third-party provider (template)

Use this when you care about a third-party provider's key and it offers a
custom OpenAI/Anthropic-compatible base URL. This is opt-in; see the direct
BYOK note below for one-off providers.

1. Add the real key on the Mac:

   ```bash
   # ~/.ai-secrets/ai-gateway.env
   REAL_FOO_API_KEY=...
   ```

2. Uncomment and edit the template block in `gateway/Caddyfile`:

   ```caddyfile
   handle_path /foo/* {
       reverse_proxy https://api.foo.com {
           header_up Host api.foo.com
           header_up Authorization "Bearer {env.REAL_FOO_API_KEY}"
           # header_up x-api-key "{env.REAL_FOO_API_KEY}"  # only if needed
       }
   }
   ```

   The route name (`foo`) is arbitrary; the upstream is the provider's
   origin. Put the provider's native base path after the route in the
   harness config — the gateway forwards it unchanged.

3. In OpenCode (v2), add a custom provider — `providers`, plural, with
   `package` + `settings`. A copy-paste file lives at
   `docs/examples/opencode-gateway-provider.jsonc`:

   ```jsonc
   {
     "providers": {
       "foo": {
         "name": "Foo (via gateway)",
         "env": ["FOO_API_KEY"],
         "package": "@opencode/ai/providers/openai-compatible",
         "settings": {
           "baseURL": "http://host.docker.internal:4000/foo/v1"
         },
         "models": {
           "foo-model": { "name": "Foo Model" }
         }
       }
     }
   }
   ```

   The base URL replaces the provider origin (`https://api.foo.com`) with
   the gateway route (`http://host.docker.internal:4000/foo`) and keeps the
   native path (`/v1`). The dummy key goes in the `FOO_API_KEY` env var in
   that project's `.ai.env` (template: `sandbox/ai.env.example`, including
   a fully worked Kimi example) — v2 reads credentials from `env`, never
   from the config file. No per-model or per-protocol rules are added to
   Caddy.

4. Seed the new key and apply the route:

   ```bash
   just seed-secrets
   just gateway-reload     # copies Caddyfile to the VM, validates, restarts
   ```

### Direct BYOK (the escape hatch)

For a one-off provider, an OAuth-only provider, or a provider that hardcodes
its endpoint, skip the gateway and use OpenCode's native `/connect` or
provider config with the real key. The key then lives in the sandbox's
`/root/.local` auth store (or the project config). That is the explicit
trade-off: maximum harness compatibility, no key isolation. Use it only for
keys you are willing to expose to a prompt-injected agent.

## Flavor: deepseek (`ai-deepseek`)

This is the DeepSeek Harness (`dsh`) **web UI**, running inside a sysbox
sandbox. The VM stays agent-less; the browser on macOS reaches the sandbox
through a published port.

### Start it

```bash
just new dsh-proj
just up dsh-proj-dsh
# prints http://localhost:3080
```

Open that URL in a browser on the Mac. DSH may print a runtime URL/token
in the startup logs; `just logs dsh-proj-dsh` shows it if you need it —
that is also where the first-auth `/deepseek?token=…` link lives.

The container command is `/usr/local/bin/dsh-web`, which binds the DSH web
server to the sandbox's eth0 address on port 3080, trusts
`localhost:${DSH_PORT}`, and advertises `http://localhost:${DSH_PORT}/`.
The compose override publishes `127.0.0.1:${DSH_PORT}:3080` on the VM;
lima forwards it to the Mac.

Each concurrent DSH project needs its own `DSH_PORT` in its
`.sandbox.env` (3080, 3081, 3082, ...). Other flavors ignore it.

Useful commands:

```bash
just dsh-url dsh-proj        # print the plain macOS URL
just logs dsh-proj-dsh       # startup log (URL/token; add -f to follow)
just attach dsh-proj-dsh     # shell inside the running sandbox
just clean dsh-proj-dsh      # stop/remove container; dsh-home volume kept
just purge dsh-proj-dsh      # also wipe dsh-home + inner images/caches
```

### Provider wiring

The baked web profile is
`/root/.dsh/profiles/web/cordis.patch.yml` (on the `dsh-home` volume after
first mount). “Cordis” is the plugin framework DSH is built on; a profile
is a stack of Cordis patch layers, and `cordis.patch.yml` is the fixed
user-layer filename chosen by DSH, not by this repo. It defines an
OpenAI-compatible custom provider:

```yaml
- id: llm-pi-ai
  config:
    providers:
      deepseek-gateway:
        displayName: DeepSeek (sandbox gateway)
        api: openai-completions
        baseURL: http://host.docker.internal:4000/deepseek/v1
        apiKeyEnv: DEEPSEEK_API_KEY
        compat:
          supportsDeveloperRole: false
          maxTokensField: max_tokens
          thinkingFormat: deepseek
        models:
          - id: deepseek-flash
            name: DeepSeek Flash
          - id: deepseek-v4-pro
            name: DeepSeek V4 Pro
- id: agent-default-model
  config:
    provider: deepseek-gateway
    model: deepseek-flash
```

`DEEPSEEK_API_KEY` is a dummy set by compose; the gateway swaps it for
`REAL_DEEPSEEK_API_KEY`. The current official API model ids are
`deepseek-flash` and `deepseek-v4-pro` — the legacy
`deepseek-chat`/`deepseek-reasoner` names were retired upstream on
2026-07-24. In **Settings → Models**, use **Fetch available models** to
refresh the list, or add the current ids by hand. The `compat` switches
are DeepSeek API compatibility settings, not gateway logic.

The workspace directory to select in the DSH UI is `/workspace`, the
project directory on the Mac bind-mounted into the sandbox.

DSH is meant to run in the sandbox. Running it on macOS directly would
bypass the sysbox boundary; the gateway would still protect the DeepSeek
key, but the agent would have macOS filesystem access. Use the flavor.

## Flavor: whiteboard (`ai-whiteboard`)

No agent baked in — a clean slate. It has the full toolchains, the inner
Docker daemon, and the dummy gateway env vars. For an ad-hoc
OpenAI-compatible tool:

```bash
export OPENAI_BASE_URL=http://host.docker.internal:4000/deepseek/v1
export OPENAI_API_KEY=sk-deepseek-sandbox-dummy
```

For OpenCode Go from an ad-hoc install, point the provider at
`http://host.docker.internal:4000/opencode-go/inference/go/v1` and use the
dummy `OPENCODE_API_KEY`.

## Troubleshooting wiring

- **403 from the gateway** — the route prefix is wrong or missing. The
  gateway default-denies anything not matching an active route.
- **401 from the upstream** — the route works but the real key is missing
  or rejected. Check `just seed-secrets` and the Mac-side secrets file.
- **The upstream's own auth error quotes the dummy** (DeepSeek:
  `Authentication Fails, Your api key: ****ummy is invalid`) — the
  request bypassed the gateway and hit the provider origin directly; a
  routed request can never leak the dummy upstream. In the opencode
  flavor the sandbox's `opencode.json` has lost (or pre-dates) the
  catalog `deepseek` endpoint-override — hand-edit it in the sandbox or
  purge the project. Do not "fix" it with `/connect` and the real key
  (direct BYOK: the real key lands inside the sandbox).
- **404/502** — path/base-URL drift or upstream unreachable. Check the
  sandbox base URL against the route table: the native path after the route
  prefix must be exactly what the harness normally sends.
- **DSH page loads but API calls fail** — check `just logs <p>-dsh`;
  confirm the
  provider base URL is `/deepseek/v1` and `DEEPSEEK_API_KEY` is the dummy.
- **DSH rejects the Host header** — the launcher trusts
  `localhost:${DSH_PORT}`; if you open a different hostname/port, add a
  `DSH_TRUSTED_HOSTS` env or adjust `compose.dsh.yaml`.
