#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_PATH="${1:-${SCRIPT_DIR}/openclaw.tgz}"
OUT_DIR="$(cd "$(dirname "${OUT_PATH}")" && pwd)"
OUT_BASENAME="$(basename "${OUT_PATH}")"

log() {
  printf '[make-openclaw-tgz] %s\n' "$*"
}

add_if_exists() {
  local path="$1"
  if [[ -e "${ROOT_DIR}/${path}" ]]; then
    FILES+=("${path}")
  fi
}

FILES=()

# Minimal runtime surface for `npm install -g <tgz>`:
# - package.json: package metadata + dependency graph
# - openclaw.mjs + dist/: CLI entry + built output
# The rest matches what `npm pack` would normally include via "files".
add_if_exists "package.json"
add_if_exists "openclaw.mjs"
add_if_exists "dist"
add_if_exists "assets"
add_if_exists "docs"
add_if_exists "extensions"
add_if_exists "skills"
add_if_exists "CHANGELOG.md"
add_if_exists "LICENSE"
add_if_exists "README.md"
add_if_exists "README-header.png"

if [[ "${#FILES[@]}" -eq 0 ]]; then
  log "ERROR: no files selected for tarball"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

log "creating tarball: ${OUT_PATH}"

# NPM tarballs are prefixed with `package/`.
TMP_OUT="${OUT_DIR}/.${OUT_BASENAME}.$$.$RANDOM.tmp"
(cd "${ROOT_DIR}" && tar -czf "${TMP_OUT}" --transform 's,^,package/,' "${FILES[@]}")
mv -f "${TMP_OUT}" "${OUT_PATH}"

log "ok"
