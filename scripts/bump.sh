#!/usr/bin/env bash
# =============================================================================
# bump.sh — refresh version pins in images/docker-bake.hcl from upstream.
#
#   scripts/bump.sh --agents      # the two agent CLIs — the weekly habit
#   scripts/bump.sh --toolchains  # node/fnm/typescript, uv, go, rust,
#                                 # cargo-binstall, base digest
#   scripts/bump.sh --all
#
# Runs ON THE MAC (needs curl + python3; no jq dependency). Wrappers:
# `just bump-agents` / `just bump-all`. Follow with `just build`.
#
# Guarantees: the file is rewritten ATOMICALLY and only with pins that
# actually resolved; any upstream fetch failure skips that pin with a
# warning instead of writing garbage. NODE_VERSION is MAJOR-pinned: the
# major is read from docker-bake.hcl and never crossed (moving majors is a
# deliberate manual edit). PYTHON_VERSION is intentionally NOT auto-bumped
# (a minor bump changes interpreter semantics; do it by hand).
# =============================================================================
set -euo pipefail

MODE="${1:---agents}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BAKE="$HERE/../images/docker-bake.hcl"

fetch() { curl -sfL --max-time 25 "$1"; }

npm_latest() { # npm_latest <@scope/name>
  fetch "https://registry.npmjs.org/${1//\//%2F}/latest" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])'
}
pypi_latest() { # pypi_latest <name> (reserved for future non-npm CLIs)
  fetch "https://pypi.org/pypi/${1}/json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])'
}
gh_latest() { # gh_latest <owner/repo> [strip-prefix]
  fetch "https://api.github.com/repos/$1/releases/latest" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' \
    | sed "s/^$2//"
}
node_lts() { # node_lts <major> — newest lts release WITHIN the pinned major
  fetch https://nodejs.org/dist/index.json | python3 -c '
import json,sys
major = sys.argv[1]
for d in json.load(sys.stdin):
    v = d["version"].lstrip("v")
    if d["lts"] and v.split(".")[0] == major:
        print(v); break
' "$1"
}
go_latest() {
  fetch "https://go.dev/dl/?mode=json" | python3 -c '
import json,sys
print(json.load(sys.stdin)[0]["version"].removeprefix("go"))'
}
rust_stable() {
  fetch https://static.rust-lang.org/dist/channel-rust-stable.toml | python3 -c '
import re,sys
toml = sys.stdin.read()
m = re.search(r"\[pkg\.rust\][^\[]*?version = \"([0-9.]+)", toml)
print(m.group(1))'
}
ubuntu_digest() {
  local token
  token="$(fetch "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
  curl -sfI --max-time 25 \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04 \
    | tr -d "\\r" | awk "tolower(\$1)==\"docker-content-digest:\"{print \$2}"
}

# -- collect updates ----------------------------------------------------------
# NOTE: no `declare -A` here — macOS /bin/bash is 3.2, which has no
# associative arrays. Each resolved pin is exported immediately as
# U_<VAR>=<value> (the python rewrite below reads them from the
# environment); N_PINS counts only the pins that actually resolved.
N_PINS=0
want() { # want <var> <resolved-value-or-empty>
  local var="$1" val="${2:-}"
  if [ -z "$val" ]; then
    echo "  !! $var: could not resolve latest — leaving current pin" >&2
  else
    export "U_$var=$val"
    N_PINS=$((N_PINS + 1))
    echo "  $var -> $val"
  fi
}

case "$MODE" in
  --agents|--all)
    echo "resolving agent CLI versions (one per flavor)..."
    want OPENCODE_VERSION    "$(npm_latest @opencode/cli || true)"
    want DSH_VERSION         "$(npm_latest @deepseek-ai/dsh || true)"
    ;;
esac
case "$MODE" in
  --toolchains|--all)
    echo "resolving toolchain versions..."
    # Read the pinned node MAJOR out of docker-bake.hcl — bump-all never
    # crosses it (moving majors is a deliberate, manual edit; UPDATES.md).
    NODE_MAJOR="$(sed -n '/variable "NODE_VERSION"/,/^}/s/^  default = "\([0-9][0-9]*\)\..*$/\1/p' "$BAKE")"
    : "${NODE_MAJOR:?could not read the pinned node major from $BAKE — file layout changed?}"
    want NODE_VERSION            "$(node_lts "$NODE_MAJOR" || true)"
    want FNM_VERSION             "$(gh_latest Schniz/fnm v || true)"
    want TYPESCRIPT_VERSION      "$(npm_latest typescript || true)"
    want UV_VERSION              "$(gh_latest astral-sh/uv v || true)"
    want GO_VERSION              "$(go_latest || true)"
    want RUST_TOOLCHAIN          "$(rust_stable || true)"
    want CARGO_BINSTALL_VERSION  "$(gh_latest cargo-bins/cargo-binstall v || true)"
    want UBUNTU_DIGEST           "$(ubuntu_digest || true)"
    ;;
esac

if [ "$N_PINS" -eq 0 ]; then
  echo "nothing to update." >&2
  exit 1
fi

# -- rewrite docker-bake.hcl (atomic; fails loudly if a pattern is missing) ----
python3 - "$BAKE" <<'PY'
import os, re, sys, tempfile

path = sys.argv[1]
with open(path) as f:
    src = f.read()

for key, val in os.environ.items():
    if not key.startswith("U_"):
        continue
    var = key[2:]
    pattern = re.compile(r'(variable "%s" \{\s*\n\s*default = ")[^"]*(")' % var)
    new, n = pattern.subn(lambda m: m.group(1) + val + m.group(2), src)
    if n == 0:
        sys.exit(f"bump.sh: variable \"{var}\" not found in {path} — file layout changed?")
    src = new

# atomic replace: never leave a half-rewritten pin file behind
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    f.write(src)
os.replace(tmp, path)
print(f"docker-bake.hcl updated ({sum(1 for k in os.environ if k.startswith('U_'))} pins).")
PY

echo "next: just build   # rebuilds only the changed layers (agents bumps are ~1-2 min)"
