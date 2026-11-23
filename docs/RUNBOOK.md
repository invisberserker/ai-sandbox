# Runbook — troubleshooting

Symptoms → causes → fixes. When in doubt: `just verify` first; it narrows
the layer faster than reading logs.

## Two network layers (read this before debugging any port)

```
[inner container]──inner netns──[sandbox netns]──bridge──[VM]──lima forward──[macOS]
                                └─ dev servers bind HERE
```

- Lima auto-forwards only what binds **in the VM** (including ports the
  OUTER daemon publishes).
- A dev server or INNER-daemon `-p` publish binds in the **sandbox's**
  netns — invisible to lima. Two ways to bridge it:
  - **persistent window** (known, contiguous dev ports): set
    `SANDBOX_PORTS=1` + `PORT_BASE`/`PORT_BASE_END` in the project's
    `.sandbox.env` — the Justfile merges `sandbox/compose.ports.yaml` on
    `just up`, publishing your window AS-IS (sandbox port N → Mac
    localhost:N). The `-dsh` flavor replaces it with its own
    (`DSH_PORT_BASE`), so both flavors of one dir coexist.
  - **ad-hoc relay** (any port, any time, live `shell` sessions too):
    `just expose <name> [HOST:CONTAINER]` — a throwaway socat relay on
    the project's own network, targeting the compose service name (a
    sandbox recreate is absorbed via DNS). `just expose <name>` (no
    spec) lists what the sandbox is listening on; `just unexpose`
    releases relays (`--all` = every relay on the VM).
- Rule of thumb when a port doesn't appear on the Mac: figure out which of
  the two boxes it bound in. `limactl shell ai-box` + `ss -ltn` inside the
  VM shows layer 2; relays show up as containers named
  `<project>-expose-<port>` (label `ai-sandbox.relay`); from there it's
  the window, a binding address, or an un-exposed port. Dev servers must
  bind `0.0.0.0` inside the sandbox (`vite --host`) — loopback-only
  listeners are invisible to any publish or relay.
- DSH is its own case: `just up <p>-dsh` publishes
  `127.0.0.1:${DSH_PORT}:3080` on the VM, which lima forwards to macOS
  `localhost:${DSH_PORT}`.

**Worked example — fullstack web app, both flavors up.** Project
`webapp`, vite on sandbox :5173, API on :5174. In `webapp/.sandbox.env`:

```bash
SANDBOX_PORTS=1
PORT_BASE=5173
PORT_BASE_END=5199
```

`just up webapp` → Mac `http://localhost:5173` (vite) and `:5174` (API).
`just up webapp-dsh` → the DSH flavor's dev servers appear inside
`DSH_PORT_BASE..` instead (default 3200-3399) plus the DSH UI on
`localhost:3080`. A port outside any window — say the agent starts a
demo on :8080 — is one command: `just expose webapp 8080`. Two sandboxes
claiming the same Mac port collide like host docker: loud
"port already allocated" — re-window one or `expose` on another number
(`just expose webapp-dsh 8081:8080`).

## Sandbox won't start: runc / "namespace" / "mount" errors

Almost always **sysbox vs kernel**. Check:

```bash
just vm-shell
uname -r                          # expect 6.8.0-xx-generic (noble GA)
apt-mark showhold                 # expect the linux-* packages held
systemctl status sysbox-mgr sysbox-fs
dmesg | tail -30                  # look for sysbox-fs / shiftfs complaints
```

Causes: an apt upgrade slipped a new kernel past the holds (re-hold +
reboot into 6.8: `sudo apt install "linux-image-$(ls /boot | grep -o '6\.8\.0-[0-9-]*generic' | head -1)" && sudo update-grub && sudo reboot` — if /boot no longer has a 6.8 kernel, install one explicitly, e.g. `sudo apt install linux-image-6.8.0-101-generic`), or the sysbox
runtime isn't registered (`docker info | grep -A5 Runtimes`; re-apply
vm/ai-box.yaml step 4's drop-in + `systemctl restart docker`).

Stopgap while fixing: the fallback profile at the bottom of
sandbox/compose.sandbox.yaml — `runtime: runc`, the outer socket mount,
and `SANDBOX_NO_DOCKERD=1` (without that env the entrypoint still tries
to rm the mounted socket and start its own dockerd — the container dies
instantly). Lose: per-project docker isolation + port collision-freedom.

## Inner dockerd fails inside a sandbox

The entrypoint prints `[sandbox-init] ERROR ... Log tail:` — read it.

- `iptables` / `DOCKER-ISOLATION` chain errors → the image's
  `iptables-legacy` switch got lost in a custom build (Dockerfile, stage
  base). Legacy is required under user namespaces.
- Stale `docker.pid` after a hard kill → entrypoint already cleans it;
  if it recurs, the volume may hold older state: `just clean <p>` then
  retry; escalate to `just purge <p>` (drops inner images).
- **Corrupted inner image store** (`failed to read ... metadata.json`):
  two causes. A SIGKILLed dockerd on the persistent volume (exactly what
  the entrypoint's graceful shutdown prevents), or a second daemon on
  the same store — which is what happens if you `just shell <p>` while
  the project is already `up`; both containers mount this project's
  `inner-docker-data` volume. If you hit it anyway: `just purge <p>`.
  Painful once, then never again.

## DNS: nested containers can't resolve

The entrypoint passes `--dns=<upstream>` to the inner daemon because
Docker refuses to hand a `127.0.0.11` resolv.conf to nested containers.
The upstream is chosen by a live probe at sandbox boot: `SANDBOX_DNS` if
set, else the sandbox gateway IF it answers a DNS query (dig, 1 s
bound), else 1.1.1.1 with a WARN in the entrypoint log. The probe exists
because the gateway is an assumption nothing provisions: the VM's plain
bridges carry no :53 listener, and dogfooded/nested deployments of this
stack (where the outer gateway equally has none) used to leave every
inner container with dead DNS. If a specific project still breaks:
inside the sandbox check `docker run --rm busybox nslookup google.com`;
override with `SANDBOX_DNS=<ip>` in the project's `.ai.env` — entrypoint
knobs are container env, and nothing interpolates `SANDBOX_*` into
`environment:`, so `.sandbox.env` cannot deliver them.
The host-proxy variant of DNS pain — `ping` going silent for seconds
behind a fakeip TUN — is the next section.

## Reverse DNS stalls behind the host's fakeip TUN (ping "silent for seconds")

**Symptom.** With a fake-ip proxy TUN on the Mac (sing-box, 198.18.0.0/15),
`ping <domain>` in the VM or a sandbox prints its header, then sits silent
for ~4–8 s before the first reply line bursts out — with sub-ms RTTs.
`curl` works everywhere; `ping -n`, pinging by IP, and busybox ping are
instant; macOS `ping` never stalls. Misdirection bonus: `ping 203.0.113.1`
"works" too — the TUN fabricates ICMP replies, so behind fake-ip ping
success proves nothing about reachability. Only TCP/UDP tests are real.

**Cause.** Linux iputils-ping blocks printing its first reply line on a
synchronous reverse (PTR) lookup of the reply address — busybox ping and
macOS BSD ping never do that lookup. A fakeip has no useful PTR, so the
behavior is decided by which path the lookup takes:

| where | PTR path | latency |
| --- | --- | --- |
| leaf containers | entrypoint `--dns` → raw UDP → host TUN hijack | sing-box answers in ~2 ms |
| VM + sandbox, before steps 3/7 | lima NAT DNS proxy → macOS resolver | ~4 s → SERVFAIL, regardless of sing-box's answer |
| macOS host | — | BSD ping does no reverse lookup |

On the sing-box side the PTR rule must answer `NXDOMAIN`, not `REFUSED`:
musl (alpine) ignores REFUSED and waits out its retry budget (~4 s), while
NXDOMAIN is a terminal negative answer for glibc and musl alike:

```json
{ "query_type": ["PTR", "HTTPS"], "action": "predefined", "rcode": "NXDOMAIN" }
```

**Stack side (vm/ai-box.yaml, provisioned).** Step 3 pins the outer
daemon's embedded resolver (`"dns": ["1.1.1.1"]`) — the upstream a sandbox's
`127.0.0.11` forwards to. Step 7 pins the VM's own `/etc/resolv.conf` to a
public IP, replacing the systemd-resolved symlink — pinning resolved.conf
globals instead would be silently ignored, because the DHCP link's per-link
DNS wins default-route lookups. Neither touches images or volumes — no
rebuild needed — and both re-apply on every VM boot. To apply live now,
from a VM shell (`just vm-shell`):

```bash
# step 3 live — restarting docker restarts every running sandbox:
sudo jq '. + {dns: ["1.1.1.1"]}' /etc/docker/daemon.json \
  | sudo tee /etc/docker/daemon.json.new
sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json
sudo systemctl restart docker

# step 7 live — rm first, or tee would write through the symlink into
# /run/systemd/resolve/stub-resolv.conf; systemd-resolved keeps running:
sudo rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\n' | sudo tee /etc/resolv.conf
```

**Verify.** In a sandbox, `dig -x "$(dig +short google.com)"` must answer
NXDOMAIN in single-digit ms (before: SERVFAIL after ~4 s), and
`time ping -c 2 google.com` must take ~2 s (before: ~8 s). Plain
`ping google.com` in the VM prints continuously. On the Mac,
`time dscacheutil -q host -a ip_address 198.18.0.25` shows the ~4 s stall
in the macOS resolver itself — the thing the VM no longer rides.

No fakeip TUN on the Mac? PTRs resolve normally end-to-end, nothing
stalls, and both pins are inert (1.1.1.1 is then just plain DNS).

## git: "detected dubious ownership"

Should never happen (`safe.directory '*'` is baked). If a custom image
hits it: `git config --system --add safe.directory '*'`. Root cause:
virtiofs files present as 65534:65534 inside the user namespace.

## Agent can't reach its provider (401/403/404/connection refused)

1. `just verify` → gateway default-deny, `caddy validate`, and route checks.
2. From inside the sandbox, test the exact base URL your harness uses:

   ```bash
   # OpenCode Go route (GET /v1/models is harmless)
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Authorization: Bearer oc_sk_sandbox_dummy' \
     http://host.docker.internal:4000/opencode-go/inference/go/v1/models

   # DeepSeek route
   curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'Authorization: Bearer sk-deepseek-sandbox-dummy' \
     http://host.docker.internal:4000/deepseek/v1/models
   ```

   200 = real key seeded and route works; 401 = route works, key missing or
   rejected → `just seed-secrets`; 403 = route prefix wrong (default deny);
   404/502 = path/base-URL drift or upstream unreachable.
3. Connection refused = gateway down on the VM:
   `systemctl status ai-gateway` inside `just vm-shell`.
4. Edited a route in `gateway/Caddyfile`? The VM uses its own copy.
   Run `just gateway-reload` (copy + validate + restart); `seed-secrets`
   only updates keys.
5. A CLI that ignores base URLs (rare, usually proprietary builds): use
   the mitmproxy ladder (SECURITY.md), direct BYOK, or pin a version that
   honors a custom endpoint. Do not add per-model logic to Caddy.
6. The provider's OWN auth error quoting the dummy — DeepSeek's
   `Authentication Fails, Your api key: ****ummy is invalid` — means the
   request reached `api.deepseek.com` DIRECTLY, not through the gateway
   (the gateway swaps the dummy in transit; a routed request can never
   leak the dummy into an upstream error). In the opencode flavor, the
   sandbox's `opencode.json` has lost (or pre-dates) the catalog
   `deepseek` endpoint-override: check
   `/root/.config/opencode/opencode.json` — volumes seeded before the
   override was baked keep the old copy, so hand-edit it or
   `just purge <project>`. Do NOT "fix" it with `/connect` and the real
   key — that is direct BYOK, the real key lands inside the sandbox.

## The echo-logging test (what OpenCode really sends per API family)

**What this test decides.** The `/opencode-go` route swaps the
`Authorization` header and drops the dummy key headers the CLI mirrors
into family requests — observed so far: `x-goog-api-key` on Gemini
models (@ai-sdk/google behavior). If upstream ever reads such a header
first, that family 401s while everything else works — and the fix is a
`header_up -<header>` drop line (not a value swap: a swap is
unconditional in Caddy and would inject the header into requests that
never sent it). The test answers two questions with evidence instead of
guesses:

1. What does OpenCode actually put on the wire per family — Bearer
   only, or a native key header? (Decides whether the commented
   `header_up` lines in `gateway/Caddyfile` stay off or get enabled.)
2. Does every family round-trip through the gateway with a real reply?

Nothing sensitive is logged: only dummy keys ever reach the gateway; the
real key is injected after the log point. Prereqs: `just verify` green
and real keys seeded (`just seed-secrets`) — bringing the stack up from
a bare Mac: `just vm-up && just build && just seed-secrets && just
verify`.

1. **Observability on the gateway.** Add inside the site block of
   `gateway/Caddyfile` (the repo copy on the Mac) — TEMP, remove when
   done — then apply with `just gateway-reload`:

   ```caddyfile
   	log {
   		output stderr
   		format console
   	}
   	handle /echo/* {
   		respond "echo: method={http.request.method} uri={http.request.uri} auth=[{http.request.header.Authorization}] x-api-key=[{http.request.header.X-Api-Key}] x-goog-api-key=[{http.request.header.X-Goog-Api-Key}] anthropic-beta=[{http.request.header.Anthropic-Beta}] session=[{http.request.header.X-Opencode-Session}]"
   	}
   ```

   From the Mac, follow the log (works from a second terminal):

   ```bash
   limactl shell ai-box -- sudo journalctl -u ai-gateway -f
   ```

   Every request through the gateway now logs method, path, request
   headers and response status. If the console lines are too dense,
   switch `format console` to `format json` and filter with jq.

2. **Plumbing check** from any sandbox — use a throwaway project so
   the config edits below never touch a real one. NOTE: the
   `host.docker.internal` name only exists INSIDE containers (docker's
   extra_hosts); from the VM shell use `http://127.0.0.1:4000`, from the
   Mac `http://localhost:4000`:

   ```bash
   just new probe && just shell probe
   ```

   ```bash
   curl -s -H 'Authorization: Bearer oc_sk_sandbox_dummy' \
        -H 'x-api-key: canary-123' \
        http://host.docker.internal:4000/echo/ping
   ```

   Expected response — both values mirrored back:

   ```
   echo: method=GET uri=/echo/ping auth=[Bearer oc_sk_sandbox_dummy] x-api-key=[canary-123] x-goog-api-key=[] anthropic-beta=[] session=[]
   ```

   That confirms sandbox → gateway reachability and that the echo
   reports exactly what Caddy received.

3. **Capture per-family headers.** In the probe sandbox, repoint the
   volume copy of the OpenCode config at the echo route, then set each
   family's default model by turn (config is re-read at TUI start; the
   /models picker can't fetch against the echo — expected):

   ```bash
   sed -i 's|/opencode-go/inference/go/v1|/echo/inference/go/v1|' /root/.config/opencode/opencode.json
   sed -i 's|"model":.*|"model": "opencode-go/<id>"|' /root/.config/opencode/opencode.json
   ```

   | Family | `<id>` | Endpoint path to expect in the log |
   | --- | --- | --- |
   | OpenAI Responses | `gpt-6-luna` | `/inference/go/v1/responses` |
   | OpenAI Chat Completions | `glm-5.3-flash` | `/inference/go/v1/chat/completions` |
   | Anthropic Messages | `claude-haiku-5-5` | `/inference/go/v1/messages` |
   | Gemini (streaming) | `gemini-4-argon` | `/inference/go/v1/models/gemini-4-argon:streamGenerateContent` |

   The CLI appends these to the baked base URL's `/v1` — paths verified
   against live traffic except Anthropic (upstream serves
   `/inference/go/v1/messages`; the Console docs also list direct
   per-family aliases like `/inference/go/openai/v1/...`).

   Launch `opencode`, send "hi", quit. The TUI errors on each send —
   the echo's plain-text reply is not valid model output. **That is the
   design**; the journal lines are the payload. The verdict:

   - `Authorization: Bearer oc_sk_sandbox_dummy` on every family (the
     gateway swaps it in transit) — expected.
   - `x-goog-api-key=[oc_sk_sandbox_dummy]` on Gemini — observed,
     already handled: the shipped route drops it (`header_up
     -x-goog-api-key`). Expect the drop, not a swap: upstream
     authenticates by Authorization for every family.
   - Any OTHER non-empty family key header (e.g. a future `x-api-key`)
     → add a matching `header_up -<header>` line to the route and
     `just gateway-reload` before step 4.

4. **Real round-trip.** Restore the route and repeat the same four
   models:

   ```bash
   sed -i 's|/echo/inference/go/v1|/opencode-go/inference/go/v1|' /root/.config/opencode/opencode.json
   ```

   Each "hi" should now stream a real reply in the TUI, with the journal
   showing the same paths under `/opencode-go/…` and status **200**. If
   a family fails:

   | Symptom | Meaning | Fix |
   | --- | --- | --- |
   | 401 | route works; the real key is missing or rejected | `just seed-secrets` from the Mac |
   | 403 | the request matched no route (default-deny) | base URL lost its `/opencode-go` prefix — check the sandbox config |
   | 404 / 502 | path / base-URL drift, or upstream unreachable | compare the logged path against the family table in step 3 |
   | one family 401s while the others 200, and step 3 showed its native key header | upstream reads the family-native header first | add a `header_up -<header>` drop line to the route (a value swap would inject it into every request), then `just gateway-reload` |

5. **Scripted cross-check** (optional; from inside the sandbox — each
   call spends a sliver of the Go allowance):

   ```bash
   B=http://host.docker.internal:4000/opencode-go/inference/go/v1
   K='Authorization: Bearer oc_sk_sandbox_dummy'
   # OpenCode Go 400s with MissingSessionID unless x-opencode-session
   # (its prompt-cache routing key, passed through by the gateway) is set:
   S="x-opencode-session: $(cat /proc/sys/kernel/random/uuid)"
   curl -s -o /dev/null -w 'responses  %{http_code}\n' -H "$K" -H "$S" -H 'content-type: application/json' \
        -d '{"model":"gpt-6-luna","input":"hi"}' $B/responses
   curl -s -o /dev/null -w 'chat       %{http_code}\n' -H "$K" -H "$S" -H 'content-type: application/json' \
        -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":16}' $B/chat/completions
   curl -s -o /dev/null -w 'anthropic  %{http_code}\n' -H "$K" -H "$S" -H 'content-type: application/json' \
        -d '{"model":"claude-haiku-5-5","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' $B/messages
   curl -s -o /dev/null -w 'gemini     %{http_code}\n' -H "$K" -H "$S" -H 'content-type: application/json' \
        -d '{"contents":[{"parts":[{"text":"hi"}]}]}' "$B/models/gemini-4-argon:generateContent"
   ```

   Four `200`s = every family works through the gateway with Bearer-only
   rewriting. A `400 MissingSessionID` means the `S` header was dropped.
   Drop `-o /dev/null` to read the actual (error) bodies.

6. **Cleanup.** Remove the TEMP `log` + `handle /echo/*` blocks from
   `gateway/Caddyfile` and `just gateway-reload` — leaving them on is
   harmless but noisy (the access log records every sandbox request).
   Then `just purge <throwaway-project>` to wipe the probe project's
   volume; its config was already repaired by step 4's sed.

Notes:

- Model ids rotate. If any of the four has moved by the time you run
  this, the Console Go docs list every model with its id, path and
  family (opencode.ai/docs/console/go — the same table these came
  from).
- Gemini was the family that carried a second key header: observed
  live as `x-goog-api-key=<dummy>`; the shipped route drops it
  (`header_up -x-goog-api-key`) because upstream authenticates by
  Authorization for every family. The echo test exists to catch the
  NEXT such header — when it shows one, add a matching drop line.

## DSH web UI: page loads, API calls fail

- `just logs <project>-dsh`: confirm the printed URL/token and that DSH
  started on the sandbox eth0 address.
- In the DSH Models page, the custom provider must be
  `http://host.docker.internal:4000/deepseek/v1` with protocol
  **OpenAI Chat Completions** and `DEEPSEEK_API_KEY` as the dummy.
- `just verify` should show `/deepseek` reaches the upstream. A 403 means
  the route is wrong; 401 means the real key is missing on the VM.
- If you open the UI via a different hostname/port, DSH's Host/Origin
  fence rejects it. Use `http://localhost:${DSH_PORT}`, or put the extra
  authority in `DSH_TRUSTED_HOSTS` in the project's `.sandbox.env`
  (space-separated; `just clean <project>-dsh` + `just up <project>-dsh`
  after changing it).
- If the page is unreachable on the Mac, check that `just up <project>-dsh`
  is used, that `DSH_PORT` is unique, and that the VM's
  `127.0.0.1:${DSH_PORT}` is listening (`ss -ltn` on the VM).

## "disk full" on the VM

Usual suspects in order:

```bash
just vm-shell
docker system df                                    # outer: dangling images
docker volume ls                                    # stale project volumes
du -sh /var/lib/docker/volumes/*/  | sort -h | tail # biggest inner-docker caches
du -sh /mnt/projects/*                              # source (should be small —
                                                    #  check for target/ or
                                                    #  node_modules in the tree)
```

Fixes: `just clean <stale-project>[-dsh]` (or `purge` if the project is
dead), `docker image prune` on
the VM. The build-cache redirect exists so
`target/` and `node_modules` DON'T land in the Mac tree — if they do,
some tool is bypassing the env (check `.cargo/config.toml` overrides or a
project-local npm config).

## VM won't boot / probes fail

```bash
limactl list
limactl start --debug ai-box         # re-run the boot with verbose errors
tail -50 ~/.lima/ai-box/ha.stderr.log  # hostagent log from the last boot
limactl shell ai-box                 # if it's up enough to try
```

Provisioning is idempotent — the standard unstick is `just vm-rebuild`
(~3-5 min). Persistent failures: check free disk on the Mac (VM disk is
sparse but grows), and that no other hypervisor pegged the machine.

Reading a stuck boot (things the probe clock won't tell you):

- The 🕐 clock spins ~13 minutes per probe (200 × 3 s retries) before
  lima moves on — "pending for ten minutes" means *failing*, not slow.
- Probe failures are silent on the console; the hostagent log names the
  failing one: `grep 'executing script' ~/.lima/<vm>/ha.stderr.log | tail`.
- The VM user's docker group is applied — and verified — by `just vm-up`
  after the boot; `just verify` re-checks it (it runs docker as the VM
  user). `docker info` failing inside vm-shell → run `just vm-up`.
- Provisioning re-runs when the hostagent starts: `just vm-stop && just
  vm-up`, or `just vm-rebuild`. A reboot from inside the VM skips it
  (same cloud-init instance-id). Scripts run under `set -x`; the trace
  is in /var/log/cloud-init-output.log.
- `failed to bind host port …: cannot assign requested address` = the
  bind address isn't on any interface. The stack discovers docker0's
  real address (mirror, gateway, probes, verify), so check
  `ip -4 addr show dev docker0`. A failed `docker run` leaves a
  **Created-state corpse**: gate on `.State.Running`, not existence.

## Performance notes

- Slow builds: confirm `CARGO_TARGET_DIR`/`npm_config_cache` are actually
  set in the session (`env | grep -E 'CARGO|npm_config'`). Compiling into
  `/workspace` (virtiofs) is 10-50x slower — the envs exist to prevent it.
- Slow image pulls *inside* sandboxes: mirror health (`curl
  http://host.docker.internal:5000/v2/` inside a sandbox). After a VM rebuild the
  mirror cache is empty; first pulls are full-size.
- `limactl shell` feels slow to connect: normal ssh multiplexing latency,
  not a VM problem.

## Escalation ladder (when something is deeply wedged)

1. `just clean <p>[-dsh]` → retry `shell`
2. `just purge <p>[-dsh]` → retry (drops inner images/caches/agent
   state; the -dsh form also drops dsh-home)
3. fallback runtime profile (see above) for *that project*
4. `just vm-rebuild`
5. `limactl delete -f ai-box && just vm-up && just build` (same as 4;
   listed for when `just` itself is the wedged part)
