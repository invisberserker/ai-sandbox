# syntax=docker/dockerfile:1
# =============================================================================
# ai-sandbox images — three flavors, ALL toolchains each; two carry an agent
# =============================================================================
#   base        : OS + system tools + inner docker engine   (changes ~never)
#   node-core   : fnm + pinned Node LTS + tsc    (changes ~quarterly)
#   toolchains  : rust + python(uv) + go — the shared big layer
#                 ↑ shipped directly as ai-whiteboard (NO agent CLI)
#   opencode    : OpenCode TUI — thin volatile tail (OpenCode Go via gateway)
#   deepseek    : DeepSeek Harness (dsh) web UI — thin volatile tail
#
# Layer order IS the update strategy (docs/UPDATES.md): the agent CLI is the
# most volatile thing in the stack, so each agent flavor is a tiny stage at
# the very end of a fully shared chain. `just bump-agents && just build`
# rebuilds each agent tail in ~1 minute; toolchains and below come free
# from the layer cache. Every flavor contains the identical toolchain set
# (node/typescript, rust, python, go) and system utils — the two agent
# flavors differ ONLY in which agent CLI (and its provider config) is
# installed; whiteboard carries none (bring your own agent ad-hoc).
#
# Agent CLIs get NO runtime magic: plain binaries on PATH + a baked config
# pointing at the credential gateway (see docs/AGENT-CONFIG.md for the
# provider wiring per CLI). Providers actually used: OpenCode Go and
# DeepSeek official, via the gateway routes in gateway/Caddyfile.
#
# ⚠ VOLUME-SHADOWING RULE (read before touching any RUN that installs under
#   /root): sandbox compose mounts persistent named volumes at /root/.config,
#   /root/.local, and (for the dsh flavor) /root/.dsh. Two consequences:
#     1. Runtime tools installed there are HIDDEN at runtime — so all
#        installers below use /usr/local/... system paths.
#     2. EXCEPT: when a named volume is FIRST mounted over a path, Docker
#        seeds it with the image's content at that path. We exploit this
#        deliberately for the opencode config (/root/.config/opencode/) and
#        the DeepSeek Harness profile (/root/.dsh/profiles/web/) so fresh
#        projects start with gateway-wired defaults, while the volume keeps
#        whatever the user edits afterwards.
#
# All version pins live in docker-bake.hcl — the single source of truth.
# That includes the base image ref: bake passes UBUNTU_IMAGE (digest-pinned
# there) to every stage; the tag-form ARG default below only serves bare
# `docker build` runs that skip bake (UPDATES.md → "The one rule").
# =============================================================================

# --- STAGE: base ---------------------------------------------------------------
# Base ref comes from docker-bake.hcl (UBUNTU_IMAGE, digest-pinned there).
ARG UBUNTU_IMAGE=ubuntu:24.04
FROM ${UBUNTU_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# System toolkit: what an agent needs before any language runtime exists.
# Curated around the things agents actually reach for — build plumbing
# (cmake/ninja/autotools), archives beyond tar.gz (7z/zstd/bz2), process and
# network debugging (strace/lsof/tcpdump/traceroute/nc/socat), the two DB
# CLIs that test services need (psql/redis-cli), git-lfs for asset repos,
# sqlite3, shellcheck for bash linting. Deliberately still a FLOOR, not the
# ceiling: root inside sysbox can `apt install` anything else at runtime.
# (Deliberately NOT baked: gdb, clang, gh — big, niche, or credential-shaped;
# install at runtime when a task needs them. `yq` is skipped because noble's
# apt ships the old 3.x python implementation, not the v4 syntax agents
# expect — `go install github.com/mikefarah/yq/v4@latest` if needed.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config autoconf automake libtool cmake ninja-build \
      ca-certificates curl wget git git-lfs jq sqlite3 xxd \
      unzip zip tar xz-utils zstd bzip2 p7zip-full file \
      ripgrep fd-find bat fzf tmux less vim nano \
      htop procps tree rsync lsof strace shellcheck \
      libssl-dev zlib1g-dev libffi-dev \
      iproute2 iptables iputils-ping dnsutils traceroute \
      netcat-openbsd socat tcpdump \
      postgresql-client redis-tools \
      openssh-client gnupg lsb-release sudo \
    # Ubuntu renames fd/bat due to package collisions; agents expect fd/bat.
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# Inner docker engine (docker-ce daemon + CLI + buildx + compose). Under
# sysbox each sandbox gets a PRIVATE /var/lib/docker backing store and unix
# socket — the agent gets a real docker all to itself, with natural
# localhost semantics for `docker compose up`.
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# Sysbox compatibility (CRITICAL): inside a user-namespace container,
# iptables-nft frequently fails to create the DOCKER-* chains, so the inner
# dockerd either breaks container networking or refuses to start. Legacy
# iptables works under user namespaces. This is THE classic "inner docker
# is broken in sysbox" footgun — do not "modernize" this line.
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy \
 && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# The /workspace bind mount arrives over virtiofs and shows up inside the
# user namespace owned by 65534:65534 — fully usable, but git's ownership
# check refuses it ("dubious ownership"). Files stay writable; only the
# check trips. Scoping to '*' is acceptable INSIDE an ephemeral sandbox.
RUN git config --system --add safe.directory '*'

# Shell niceties for humans riding along with agents (works for both login
# shells and `docker exec ... bash` interactive shells via the .bashrc hook).
COPY rootfs/etc/profile.d/ai-sandbox.sh /etc/profile.d/ai-sandbox.sh
RUN printf '\n# ai-sandbox: shared profile (PATH niceties, aliases)\n[ -f /etc/profile.d/ai-sandbox.sh ] && . /etc/profile.d/ai-sandbox.sh\n' >> /root/.bashrc

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Agent-managed git helper (opt-in per project via .ai.env — see
# docs/SECURITY.md → "Git auth"): materializes the project's dedicated
# SSH key into ~/.ssh + pins it for the forge host. No-op without
# GIT_SSH_KEY_B64; called from the profile hook, never the entrypoint.
COPY --chmod=0755 rootfs/usr/local/bin/agent-git-auth /usr/local/bin/agent-git-auth

# Present even when the image runs WITHOUT the compose volume mounts (e.g.
# `docker run` smoke tests) so WORKDIR and cache dirs always exist.
RUN mkdir -p /workspace /var/cache/build-targets

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bash"]

# --- STAGE: node-core (node + typescript) -----------------------------------------
# Node lives below toolchains because the agent CLIs (the two agent
# flavors) are npm-distributed. TypeScript ships globally (tsc) for
# repo-less scratch work. Node ≥25 no longer bundles corepack — projects
# needing pnpm/yarn install them directly (npm i -g pnpm yarn).
FROM base AS node-core
ARG FNM_VERSION=unknown
ARG NODE_VERSION=unknown
ARG TYPESCRIPT_VERSION=unknown

# FNM_DIR is a SYSTEM path on purpose: the default (~/.local/share/fnm) is
# shadowed by the /root/.local volume at runtime (see header note). The
# aliases/default symlink gives a stable PATH entry independent of $HOME.
ENV FNM_DIR=/usr/local/share/fnm \
    PATH="/usr/local/share/fnm/aliases/default/bin:${PATH}" \
    npm_config_cache=/var/cache/build-targets/npm

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) asset="fnm-arm64.zip" ;; \
      amd64) asset="fnm-linux.zip" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/${asset}" -o /tmp/fnm.zip; \
    unzip -q /tmp/fnm.zip -d /tmp/fnm; \
    install -m 0755 /tmp/fnm/fnm /usr/local/bin/fnm; \
    rm -rf /tmp/fnm /tmp/fnm.zip; \
    fnm install "${NODE_VERSION}"; \
    fnm default "${NODE_VERSION}"; \
    npm install -g --no-fund --no-audit "typescript@${TYPESCRIPT_VERSION}"; \
    node --version && npm --version && tsc --version

# --- STAGE: toolchains (rust + python + go — the shared big layer) -----------------
# Everything language-shaped lands here, ONE stage, shared by all flavors.
# This stage is ALSO shipped directly as the `ai-whiteboard` flavor:
# full toolchains + utils + inner docker, ZERO agent CLIs — the clean-slate
# image (npx …, uv tool install …, curl whatever).
# Build time note: this stage is the bulk of the matrix; it only rebuilds
# when a toolchain pin changes (monthly-ish, via just bump-all).
FROM node-core AS toolchains
ARG UV_VERSION=unknown
ARG PYTHON_VERSION=unknown
ARG GO_VERSION=unknown
ARG RUST_TOOLCHAIN=unknown
ARG CARGO_BINSTALL_VERSION=unknown

# --- python via uv -----------------------------------------------------------
# Relocate ALL of uv's state off /root/* (volume-shadowing header note):
# managed pythons, tool venvs and the tool-bin dir must survive the mounts.
# uv ships in toolchains (not per-flavor) — every flavor gets it.
ENV UV_PYTHON_INSTALL_DIR=/usr/local/uv-python \
    UV_TOOL_DIR=/usr/local/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_CACHE_DIR=/var/cache/build-targets/uv \
    UV_PYTHON_PREFERENCE=only-managed

# uv: pinned via direct release tarball (not the astral.sh installer script)
# so the pin in docker-bake.hcl is the whole truth.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) target="aarch64-unknown-linux-gnu" ;; \
      amd64) target="x86_64-unknown-linux-gnu" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${target}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/uv-${target}/uv" "/tmp/uv-${target}/uvx" /usr/local/bin/; \
    rm -rf "/tmp/uv-${target}"; \
    uv --version

# Pinned managed CPython. Intended workflow inside a sandbox: `uv init` /
# `uv venv` / `uv add ...` per project — no global site-packages to pollute.
RUN uv python install "${PYTHON_VERSION}" \
 && uv python find "${PYTHON_VERSION}"

# Bare `python3`/`python` on PATH: agents and shell scripts expect it, and
# the distro ships no python by default. One python in the image — the
# uv-managed interpreter (symlink, so there is nothing else to keep in
# sync). Other minors stay one command away: `uv python install 3.15`.
RUN set -eux; \
    ln -sf "$(uv python find "${PYTHON_VERSION}")" /usr/local/bin/python3 \
 && ln -sf /usr/local/bin/python3 /usr/local/bin/python \
 && python3 --version

# --- go ------------------------------------------------------------------------
# GOCACHE/GOMODCACHE redirected to the build-cache volume (VM-native ext4)
# for the same reason as CARGO_TARGET_DIR below. GOPATH keeps its default
# (/root/go) — NOT one of the shadowed paths; `go install`ed tools being
# ephemeral-with-the-container is acceptable.
ENV PATH="/usr/local/go/bin:${PATH}" \
    GOCACHE=/var/cache/build-targets/go-build \
    GOMODCACHE=/var/cache/build-targets/go-mod

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) goarch="arm64" ;; \
      amd64) goarch="amd64" ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" \
      | tar -xz -C /usr/local; \
    go version

# --- rust ----------------------------------------------------------------------
# RUSTUP_HOME/CARGO_HOME on system paths for uniformity. CARGO_TARGET_DIR
# keeps target/ off the virtiofs-mounted /workspace and on the build-cache
# volume (VM-native ext4) — the single biggest rustc speed win here.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH="/usr/local/cargo/bin:${PATH}" \
    CARGO_TARGET_DIR=/var/cache/build-targets/cargo

# minimal profile + explicit components: skips rust-docs (~400MB) while
# keeping the analyzer/formatter/linter agents actually use.
RUN set -eux; \
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
    sh /tmp/rustup-init.sh -y --profile minimal \
      --default-toolchain "${RUST_TOOLCHAIN}" \
      --component rust-analyzer,rust-src,rustfmt,clippy; \
    rm -f /tmp/rustup-init.sh; \
    rustc --version && cargo --version

# cargo-binstall: prebuilt-binary installs for cargo tools (agents can add
# cargo-llvm-tools etc. in seconds without compiling from source).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) target="aarch64-unknown-linux-musl" ;; \
      amd64) target="x86_64-unknown-linux-musl" ;; \
    esac; \
    curl -fsSL "https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}/cargo-binstall-${target}.tgz" \
      | tar -xz -C /tmp; \
    install -m 0755 /tmp/cargo-binstall /usr/local/cargo/bin/; \
    rm -f /tmp/cargo-binstall; \
    cargo binstall -V

# --- STAGE: opencode flavor --------------------------------------------------------
# Thin tail: OpenCode TUI + gateway-wired OpenCode Go provider config.
FROM toolchains AS opencode
ARG OPENCODE_VERSION=unknown
# OpenCode v2 ships as @opencode/cli on npm (docs: `npm install -g
# @opencode/cli`, or `curl -fsSL https://opencode.ai/v2/install | bash`).
# The legacy `opencode-ai` package is the frozen v1 line — do not go back.
# Pinned so docker-bake.hcl stays the whole truth.
RUN npm install -g --no-fund --no-audit "@opencode/cli@${OPENCODE_VERSION}" \
 && npm cache clean --force \
 && opencode --version
# Provider config (OpenCode Go through the gateway), in the v2 config
# schema ("endpoint override" pattern from the OpenCode v2 providers
# docs): the catalog `opencode-go` provider keeps its package/models and
# only its settings.baseURL is pointed at the gateway; the dummy key
# arrives through the provider's standard env vars, which compose sets.
# Lives under /root/.config/opencode/ — a named-volume path, so Docker
# seeds a FRESH project volume with this file on first mount; user edits
# persist on the volume afterwards. See docs/AGENT-CONFIG.md before
# changing models. NOTE: a v1-format config (singular `provider` +
# `options.*`) is silently IGNORED by v2 — keep this file in v2 shape.
COPY rootfs/root/.config/opencode/opencode.json /root/.config/opencode/opencode.json

# --- STAGE: deepseek flavor (DeepSeek Harness web UI) --------------------------------
# DSH is a web app, not a TUI. It runs INSIDE a sysbox sandbox (the VM stays
# agent-less); the browser on macOS reaches it through the DSH port override
# (sandbox/compose.dsh.yaml + `just dsh-up <project>`).
#
# Provider wiring is baked into the web profile and points at the gateway:
#   http://host.docker.internal:4000/deepseek/v1
# The sandbox holds only DEEPSEEK_API_KEY=sk-deepseek-sandbox-dummy; the
# gateway swaps it for REAL_DEEPSEEK_API_KEY in transit. The DSH config uses
# the generic pi-ai OpenAI-compatible adapter, with DeepSeek compat switches.
#
# /root/.dsh is a named volume at runtime (compose.dsh.yaml): Docker seeds a
# fresh volume from the image content on first mount; later edits persist.
FROM toolchains AS deepseek
ARG DSH_VERSION=unknown
ENV DSH_HOME=/root/.dsh
RUN npm install -g --no-fund --no-audit "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force \
 && dsh --version
COPY rootfs/root/.dsh/profiles/web/cordis.patch.yml /root/.dsh/profiles/web/cordis.patch.yml
COPY --chmod=0755 rootfs/usr/local/bin/dsh-web /usr/local/bin/dsh-web
# The entrypoint still supervises the inner dockerd; this CMD runs DSH as
# the session process. `just attach`/`docker compose exec agent bash` gives
# a shell alongside it.
CMD ["/usr/local/bin/dsh-web"]
