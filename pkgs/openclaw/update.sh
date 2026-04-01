#!/usr/bin/env bash
# Regenerates all version-pinned values in default.nix and package-lock.json.
# Run from anywhere; paths are resolved relative to this script.
#
# Requirements in PATH: curl, jq, npm (>=10), nix, prefetch-npm-deps
# Quick start:  nix run .#update
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVATION="$SCRIPT_DIR/default.nix"
LOCKFILE="$SCRIPT_DIR/package-lock.json"

# ── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "  [nyxorn/update] $*"; }
die()   { echo "  [nyxorn/update] ERROR: $*" >&2; exit 1; }

require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found in PATH"
  done
}

# ── check deps ───────────────────────────────────────────────────────────────

require curl jq npm nix

# prefetch-npm-deps ships with nixpkgs; fall back to nix-shell if missing
if ! command -v prefetch-npm-deps >/dev/null 2>&1; then
  info "prefetch-npm-deps not in PATH — wrapping via nix-shell"
  prefetch-npm-deps() {
    nix-shell -p prefetch-npm-deps --run "prefetch-npm-deps $*"
  }
fi

# ── version check ─────────────────────────────────────────────────────────────

LATEST=$(curl -sf https://registry.npmjs.org/openclaw/latest | jq -r .version)
CURRENT=$(grep -oP '(?<=version = ")[^"]+' "$DERIVATION" | head -1)

info "current: $CURRENT"
info "latest:  $LATEST"

if [[ "$LATEST" == "$CURRENT" ]]; then
  info "Already at latest — nothing to do."
  exit 0
fi

TARBALL_URL="https://registry.npmjs.org/openclaw/-/openclaw-${LATEST}.tgz"

# ── fetchzip hash ─────────────────────────────────────────────────────────────

info "Computing fetchzip hash for $LATEST …"
RAW_HASH=$(nix-prefetch-url --unpack "$TARBALL_URL" 2>/dev/null | tail -1)
NEW_SRC_HASH=$(nix hash convert --hash-algo sha256 --to sri "$RAW_HASH")
info "  fetchzip hash: $NEW_SRC_HASH"

# ── package-lock.json ─────────────────────────────────────────────────────────

info "Generating package-lock.json for $LATEST …"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -sL "$TARBALL_URL" \
  | tar -xz -C "$TMPDIR" --strip-components=1 package/package.json

(cd "$TMPDIR" && npm install --package-lock-only --ignore-scripts --silent 2>/dev/null)
cp "$TMPDIR/package-lock.json" "$LOCKFILE"
info "  package-lock.json updated ($(wc -l < "$LOCKFILE") lines)"

# ── npmDepsHash ───────────────────────────────────────────────────────────────

info "Computing npmDepsHash …"
NEW_DEPS_HASH=$(prefetch-npm-deps "$LOCKFILE")
info "  npmDepsHash: $NEW_DEPS_HASH"

# ── patch default.nix ────────────────────────────────────────────────────────

OLD_SRC_HASH=$(grep -oP '(?<=hash = ")[^"]+' "$DERIVATION")
OLD_DEPS_HASH=$(grep -oP '(?<=npmDepsHash = ")[^"]+' "$DERIVATION")

sed -i \
  -e "s|version = \"${CURRENT}\"|version = \"${LATEST}\"|" \
  -e "s|hash = \"${OLD_SRC_HASH}\"|hash = \"${NEW_SRC_HASH}\"|" \
  -e "s|npmDepsHash = \"${OLD_DEPS_HASH}\"|npmDepsHash = \"${NEW_DEPS_HASH}\"|" \
  "$DERIVATION"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "  openclaw $CURRENT → $LATEST"
echo ""
echo "  Files changed:"
echo "    pkgs/openclaw/default.nix"
echo "    pkgs/openclaw/package-lock.json"
echo ""
echo "  Next steps:"
echo "    nix build .#openclaw            # verify the build"
echo "    git add pkgs/openclaw && git commit -m 'openclaw: $CURRENT -> $LATEST'"
