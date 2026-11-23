# Security model

## What this design defends against

The threat is a **competent-but-confused or injected coding agent** doing
damage: rm-rf'ing the workspace, exfiltrating credentials it can reach,
installing persistence, or hammering shared resources. The model is
containment + credential isolation, not intrusion detection.

## The four walls

| # | Wall | Stops | Doesn't stop |
| --- | --- | --- | --- |
| 0 | Scoped virtiofs mounts: the VM sees only `~/ai-projects` (writable) and `~/.ai-secrets` (read-only) | Any access to `~/.ssh`, `~/.aws`, browser profiles, the rest of the Mac filesystem; tampering with the Mac's only copy of the keys (read-only share) | Damage *within* ~/ai-projects — commit often; the VM can still READ the key file (the gateway must) |
| 1 | sysbox user namespace: sandbox root = unprivileged UID on the VM; no `privileged:true` anywhere | VM takeover from a sandbox; one sandbox touching another's processes/sockets | Resource abuse (handled by wall 3) |
| 2 | Private inner dockerd per sandbox | `docker system prune` etc. hitting other projects; sibling-container port collisions | Anything happening *inside* its own docker |
| 3 | Per-sandbox cgroup ceilings (`cpus`, `mem_limit`, `pids_limit`) | One agent starving the shared VM pool; fork bombs | Slow, legal-but-heavy builds |

Resource ceilings default to 4 CPU / 8 GB / 2048 PIDs per sandbox — tune
per project in its `.sandbox.env`, remembering they all share the VM's
pool.

## Credential isolation

The gateway is a **protocol-blind key swapper**. It holds the real keys,
strips a route prefix, forwards the native path to one upstream, and
replaces the dummy `Authorization` value. It does not parse model ids or
translate OpenAI/Anthropic/Gemini payloads.

```
OpenCode TUI / DSH web (sandbox)              VM root namespace
  dummy key + gateway base URL  ──────►  Caddy :4000
                                          /opencode-go → opencode.ai
                                          /deepseek    → api.deepseek.com
                                          inject real Authorization
                                                │ TLS verify upstream
                                                ▼
                                       provider APIs
```

| Flavor | What the sandbox holds | Gateway route | Upstream |
| --- | --- | --- | --- |
| opencode | `OPENCODE_API_KEY=oc_sk_sandbox_dummy`, `DEEPSEEK_API_KEY=sk-deepseek-sandbox-dummy`; baked `opencode.json` endpoint-overrides the catalog `opencode-go` provider to `/opencode-go/inference/go/v1` and the catalog `deepseek` provider to `/deepseek/v1` | `/opencode-go`, `/deepseek` | OpenCode Console (`https://opencode.ai/inference/go/v1`); DeepSeek official (`https://api.deepseek.com`) |
| deepseek | `DEEPSEEK_API_KEY=sk-deepseek-sandbox-dummy`; baked DSH profile base URL `/deepseek/v1` | `/deepseek` | `https://api.deepseek.com` |
| whiteboard / ad-hoc | `OPENAI_API_KEY=sk-deepseek-sandbox-dummy` | `/deepseek` | DeepSeek official |

Properties (for gateway-routed providers):

- `env`, `/proc/self/environ`, memory dumps, config files — all yield
  dummies. Real keys transit only the VM's root namespace.
- The gateway **default-denies** (403) anything not on a provider route —
  a misconfigured CLI fails loudly instead of quietly bypassing.
- Real keys exist in exactly two places: the Mac's
  `~/.ai-secrets/ai-gateway.env` (0600, outside any repo, shared into the
  VM **read-only**) and the VM's root-only copy. Neither is bind-mounted
  into any sandbox — sandboxes see only their `~/ai-projects/<project>`
  subdirectory, never the secrets share.
- OpenCode Go's protocol/model routing happens inside the TUI and Console,
  not in Caddy. One route covers Chat Completions, Responses, Anthropic
  Messages and Gemini; there is no per-model gateway surface to keep in
  sync.
- The gateway is a **capability**, not just a secret store: any sandbox can
  use a routed provider through it. Provider-side usage limits and the
  routes you enable are the control surface. Per-project gateway tokens
  are a possible hardening step, not implemented.

### Third-party providers in the OpenCode flavor

Two modes, deliberately:

1. **Gateway-isolated** — add one route per provider origin (the commented
   `/foo` template in `gateway/Caddyfile`) and a dummy key. The real key
   stays on the VM. Use this for keys you care about.
2. **Direct BYOK** — use OpenCode's native `/connect` or provider config
   with the real key. This is the escape hatch for one-off providers,
   OAuth-only providers, or endpoints that cannot use a custom base URL.
   The key then lives in the sandbox and is exfiltratable; that is the
   trade-off.

### DSH web UI

The DeepSeek Harness flavor runs its web UI **inside the sysbox sandbox**.
The port is published on the VM loopback (`127.0.0.1:${DSH_PORT}`) and
lima forwards it to macOS `localhost`. The VM remains agent-less.

- The real DeepSeek key is on the VM only; DSH holds the dummy.
- The DSH UI is reachable by anything that can reach the Mac's localhost
  and by anyone with local access to the Mac. Protect the Mac account;
  stop the container (`just clean <p>-dsh`) when not in use.
- DSH's `--trusted-host` fence accepts `localhost:${DSH_PORT}`; it does
  not add authentication by itself. If DSH prints a runtime token/URL,
  use it.

### Subscription OAuth (archived)

The shared `ai-identity` volume for Claude Code / Codex subscription
logins was removed: it put real long-lived refresh tokens inside the
sandbox and shared one auth file across concurrent projects. The design,
costs, and restore notes are in [ARCHIVE.md](ARCHIVE.md). Prefer
`claude setup-token` + a gateway route for Claude. For Codex / ChatGPT
subscriptions, the two designs (scoped shared volume vs refresh-aware
token sidecar) are written up in [OPENAI-PLUS.md](OPENAI-PLUS.md).

## Git auth

Default posture: **sandboxes commit, you push from the Mac.** For
projects you offload completely — a written AGENTS.md/SPEC.md
constrains the agent, and you accept pushes without per-diff review —
opt into **agent-managed git** with a dedicated key that exists only
for the sandbox:

1. Generate a dedicated key on the Mac:
   `ssh-keygen -t ed25519 -f ~/.ssh/agent_ed25519 -C "ai-sandbox: <p>"`,
   then register the public half at the forge as either:
   - a **per-repo deploy key with write access** (recommended — scope:
     exactly one repo), or
   - an **account SSH key** (scope: every repo you can push — bigger
     blast radius; accept that consciously).
2. Put the private half, as single-line base64
   (`base64 < ~/.ssh/agent_ed25519 | tr -d '\n'`), in that project's
   `.ai.env` as `GIT_SSH_KEY_B64` — optionally with
   `GIT_AGENT_NAME`/`GIT_AGENT_EMAIL` for the commit identity. The
   full recipe and template live in `sandbox/ai.env.example`.
3. Nothing else: every shell in that sandbox installs the key via the
   baked `agent-git-auth` (idempotent; headless scripts call it
   explicitly). `~/.ssh` is not a volume, so the key never persists —
   each fresh container re-derives it from the env var, `just clean`
   forgets it. The ssh config pins `IdentitiesOnly` for the forge host
   and `accept-new` host keys (trust-on-first-use — pragmatic for an
   ephemeral sandbox). The remote must be SSH form:
   `git@github.com:<owner>/<repo>.git`.

Before letting the agent loose, a 30-second pre-flight in the project
shell:

```bash
git remote -v                        # SSH form? if not:
git remote set-url origin git@github.com:<owner>/<repo>.git
git config --get user.name           # set? (auto when GIT_AGENT_* above)
git ls-remote origin                 # proves key + remote + repo access
```

Two caveats. `.ai.env` is read at container start — if you added the
key line after `just up`, restart the sandbox (`just clean` + `just
up`; shell-mode containers pick it up on the next `just shell`). And
GitHub-side branch protection rejects direct pushes to protected
branches — allow them for this flow, or have the agent work on
branches.

What a prompt-injected agent gains: push access to whatever the key
covers, without review. Mitigate with per-repo deploy keys, branch
protection on the receiving repo, and opting in only projects whose
AGENTS.md/SPEC.md you actually trust.

The rest of the ladder, in ascending exposure:

2. Mac ssh-agent forwarding (commented block in
   `sandbox/compose.sandbox.yaml`): convenient, but a rogue agent can
   *use* any loaded key (sign, authenticate) without reading key
   material. Per-project trust decision.
3. HTTPS PAT in env — no. That's a real account credential inside a
   sandbox.

## Egress posture (honest scope)

Default: **open egress from sandboxes** (registries, docs, provider APIs
via the gateway). Agents doing real work need the internet; an allowlist
tight enough to be safe is tight enough to break them. Two egress paths
are closed by default:

- **Sandbox → Mac localhost.** Lima's user-mode network would otherwise
  map the Mac's loopback into the guest as `host.lima.internal`
  (192.168.5.2) — a path from any sandbox to unauthenticated dev services
  on your Mac's localhost. `vm/ai-box.yaml` sets
  `networkOpts.hostLoopback: false` (lima ≥ 2.3, vz) to close it; DNS,
  outbound access and `limactl shell` keep working.
- **Sandbox → Mac filesystem.** Only the project bind mount exists
  (wall 0); there is no docker.sock mount, no ssh-agent socket, no
  home sharing.

If you need exfiltration control for a specific project beyond that, the
ladder:

1. Per-project: drop a `DOCKER-USER`-style constraint — not available per
   sandbox netns; skip.
2. VM-wide: run the mitmproxy pattern — `mitmdump` on the VM root ns,
   CA cert baked into an image build-arg variant, `HTTPS_PROXY` set in
   that project's `.ai.env`, allowlist script rejecting non-listed hosts.
   Costs: every new dependency needs an allowlist edit; some CLIs need CA
   wiring (`NODE_EXTRA_CA_CERTS`).
3. Escalate to no-network sandboxes (`network_mode` + internal bridge)
   for pure-offline refactors.

These are documented rather than shipped: enabling them wrong breaks more
work than it protects. Ask before giving an agent the keys to exfiltrate
*to*, not from.

## Known residual risks (accepted)

- **virtiofs is writable both ways**: a sandbox trashing `/workspace`
  trashes the Mac copy. Mitigate with git, not with walls.
- **VM kernel escape from a user-ns sandbox**: requires a kernel 0day;
  the pinned kernel raises patch latency slightly (your call, documented
  in UPDATES.md).
- **The gateway VM process** holds real keys in env; a VM-root compromise
  reads them. Moving the gateway to the Mac removes the VM copy if that
  matters to you.
- **OpenCode Go / DeepSeek usage is shared** across every sandbox that can
  reach the gateway. A compromised sandbox can spend your allowance; it
  cannot read the key.
- **Direct BYOK** keys used inside the OpenCode flavor are real
  credentials in the sandbox by design. Gateway-isolate a provider if
  that is not acceptable.
- **Agent-managed git** (opt-in per project) hands a prompt-injected
  agent push access to whatever the dedicated key covers, without
  review. Scope it with per-repo deploy keys and branch protection; the
  default posture (commit in sandbox, push from the Mac) is unaffected.
- **DSH web UI** is a localhost service with no extra auth layer; the
  sandbox's network namespace and the VM loopback are the boundary. Keep
  DSH inside the sandbox; running it on macOS would bypass sysbox.

## Verifying the walls yourself

Inside any sandbox:

```bash
cat /proc/self/uid_map    # "0 165536 65536" → root inside ≠ root on VM
docker ps                 # empty → private daemon, no siblings
ls /                      # no /mnt/projects → no VM-level view of the host tree
env | grep -i key         # dummies only (unless you opted into direct BYOK)
```

From the Mac: `just verify` asserts all of the above programmatically,
plus gateway route reachability (`/opencode-go`, `/deepseek`) and
`caddy validate`.
