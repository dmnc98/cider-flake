# shellcheck shell=bash
# Shared helpers for the cider-flake maintenance scripts. Sourced, not run.

SOURCES_REL="pkgs/cider/sources.json"

# Print the path to pkgs/cider/sources.json. Under `nix run` the calling script
# lives in the store, so $0 is useless — prefer the checkout we were invoked
# from. Every candidate must actually contain the pin, so these scripts never
# touch an unrelated directory.
find_sources_file() {
  local candidate
  for candidate in \
    "${CIDER_FLAKE_ROOT:-}" \
    "$(git rev-parse --show-toplevel 2>/dev/null || true)" \
    "$(CDPATH="" cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd || true)"; do
    if [ -n "$candidate" ] && [ -f "$candidate/$SOURCES_REL" ]; then
      printf '%s\n' "$candidate/$SOURCES_REL"
      return 0
    fi
  done

  cat >&2 <<EOM
$(basename "$0"): could not find $SOURCES_REL.

This script operates on a cider-flake checkout, so it needs one. Either:

  git clone https://github.com/dmnc98/cider-flake && cd cider-flake
  nix run .#$(basename "$0" .sh)

or point it at an existing checkout:

  CIDER_FLAKE_ROOT=/path/to/cider-flake nix run github:dmnc98/cider-flake#$(basename "$0" .sh)

To just install or run Cider you do not need this script at all:

  nix run github:dmnc98/cider-flake
EOM
  return 1
}

# Echo a key=value line, and append it to $GITHUB_OUTPUT when running in CI.
emit() {
  printf '%s\n' "$1"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
  fi
}

# The tag this repo uses for a given Cider version. Tags track Cider's own
# version exactly, with a `v` prefix: Cider 4.0.17 -> v4.0.17.
version_tag() {
  printf 'v%s\n' "$1"
}
