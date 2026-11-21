# =============================================================================
# docker-bake.hcl — SINGLE SOURCE OF TRUTH for every image pin
# =============================================================================
# `just build` stamps TWO tags per image:
#     ai-<flavor>:latest    — what compose.sandbox.yaml consumes by default
#     ai-<flavor>:YYYYMMDD  — what you pin a project to (in its .env)
#                             when you want a known-good, reproducible day
#
# Refresh pins with `just bump-agents` / `just bump-all` (scripts/bump.sh
# queries npm / GitHub / upstream dist indexes, then rewrites the defaults
# below). Edit manually any time; the file is the contract — keep the
# `variable "X" { default = "..." }` shape: bump.sh rewrites by pattern.
#
# Three flavors, identical toolchains; two carry one agent CLI each, one
# carries none (see Dockerfile):
#   ai-opencode     OpenCode TUI + baked opencode.json (OpenCode Go +
#                    DeepSeek endpoint-overrides)
#   ai-deepseek     DeepSeek Harness web UI + baked web profile
#   ai-whiteboard   NO agent CLI — a clean slate: full toolchains + utils,
#                   for working with any agent ad-hoc (npx …, uv tool
#                   install …, or download whatever the task needs)
#
# The ubuntu base digest lives ONLY here. The Dockerfile takes the whole
# base image ref as the UBUNTU_IMAGE build-arg, and bake passes it to every
# target below (shared_base), so all flavors build from the same pinned
# ref. The tag-form ARG default in the Dockerfile only serves bare
# `docker build` runs that skip bake.
# =============================================================================

# Date tag stamp: `just build` exports IMAGE_TAG=$(date +%Y%m%d); bake
# uses a same-named env var as the variable value (unset → "latest").
variable "IMAGE_TAG" {
  default = "latest"
}

# --- base image (digest-pinned: reproducible; `just bump-all` refreshes it) ----
variable "UBUNTU_DIGEST" {
  default = "sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289"
}

# --- node-core (stable-ish cadence) ----------------------------------------------
variable "FNM_VERSION" {
  default = "1.39.0"
}
# MAJOR pinned: `bump-all` only ever takes newer releases WITHIN the major
# it reads from the line below (scripts/bump.sh). Moving majors (e.g. 26 →
# 28) is a deliberate, manual edit — see UPDATES.md.
variable "NODE_VERSION" {
  default = "26.13.1" # current LTS line
}
variable "TYPESCRIPT_VERSION" {
  default = "7.0.2"
}

# --- shared toolchains (monthly-ish cadence — `just bump-all`) ---------------------
variable "UV_VERSION" {
  default = "0.13.9"
}
# 3.14 deliberately over 3.15 (weeks old; binary-wheel ecosystems lag a
# fresh CPython minor). `uv python install 3.15` inside any sandbox covers
# the edge cases. NOT auto-bumped — a minor bump changes interpreter
# semantics; edit by hand.
variable "PYTHON_VERSION" {
  default = "3.14" # uv resolves the latest patch of this minor
}
variable "GO_VERSION" {
  default = "1.27.4"
}
variable "RUST_TOOLCHAIN" {
  default = "1.100.0"
}
variable "CARGO_BINSTALL_VERSION" {
  default = "1.27.0"
}

# --- agent CLIs (VOLATILE — refresh weekly-ish with `just bump-agents`) ------------
# Each pin rebuilds exactly ONE thin flavor stage on top of the shared
# toolchains layer (≈1 min per flavor with warm cache).
# OpenCode v2 ships as @opencode/cli on npm (docs: `npm install -g
# @opencode/cli` / `curl -fsSL https://opencode.ai/v2/install | bash`);
# the legacy `opencode-ai` package is the frozen v1 line.
variable "OPENCODE_VERSION" {
  default = "2.3.2"
}
variable "DSH_VERSION" {
  default = "0.2.2-rc.5" # upstream "latest" dist-tag is itself an rc — accepted
}

# --- shared args (everything below needs the pinned base ref) --------------------
shared_base = {
  UBUNTU_IMAGE = "ubuntu:24.04@${UBUNTU_DIGEST}"
}
shared_common = {
  FNM_VERSION        = "${FNM_VERSION}"
  NODE_VERSION       = "${NODE_VERSION}"
  TYPESCRIPT_VERSION = "${TYPESCRIPT_VERSION}"
}
shared_toolchains = {
  UV_VERSION             = "${UV_VERSION}"
  PYTHON_VERSION         = "${PYTHON_VERSION}"
  GO_VERSION             = "${GO_VERSION}"
  RUST_TOOLCHAIN         = "${RUST_TOOLCHAIN}"
  CARGO_BINSTALL_VERSION = "${CARGO_BINSTALL_VERSION}"
}

# --- targets --------------------------------------------------------------------------

target "base" {
  dockerfile = "Dockerfile"
  target     = "base"
  args       = merge(shared_base)
  tags = ["ai-base:latest", "ai-base:${IMAGE_TAG}"]
}

# whiteboard = the shared toolchains stage, shipped directly: node+ts, rust,
# python(uv), go, system utils, inner docker — zero agent CLIs, a clean slate.
target "whiteboard" {
  dockerfile = "Dockerfile"
  target     = "toolchains"
  args       = merge(shared_base, shared_common, shared_toolchains)
  tags = ["ai-whiteboard:latest", "ai-whiteboard:${IMAGE_TAG}"]
}

target "opencode" {
  dockerfile = "Dockerfile"
  target     = "opencode"
  args       = merge(shared_base, shared_common, shared_toolchains, { OPENCODE_VERSION = "${OPENCODE_VERSION}" })
  tags = ["ai-opencode:latest", "ai-opencode:${IMAGE_TAG}"]
}

target "deepseek" {
  dockerfile = "Dockerfile"
  target     = "deepseek"
  args       = merge(shared_base, shared_common, shared_toolchains, { DSH_VERSION = "${DSH_VERSION}" })
  tags = ["ai-deepseek:latest", "ai-deepseek:${IMAGE_TAG}"]
}

# `just build` builds all three flavors. whiteboard is the shared toolchains
# stage itself (zero marginal cost beyond its tag); the two agent tails
# stack on top of the same layers.
group "default" {
  targets = ["base", "whiteboard", "opencode", "deepseek"]
}
