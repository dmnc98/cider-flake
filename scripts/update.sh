#!/usr/bin/env bash
# Discover the newest Cider release in Cider Collective's public APT pool and
# rewrite pkgs/cider/sources.json to point at it.
#
# Exits 0 and prints "updated=false" when already current, so CI can branch on
# it without treating "nothing to do" as a failure.
#
#   ./scripts/update.sh                 # bump to the newest version
#   ./scripts/update.sh --version 4.0.16  # pin a specific version
#   ./scripts/update.sh --dry-run       # report only, touch nothing
set -euo pipefail

POOL_URL="https://repo.cider.sh/apt/pool/main"
# Nix systems to pin, in the order they are written to sources.json. Keeping
# this an ordered list (not just the associative array) makes the generated
# JSON byte-stable, so the bot never commits a pure key-reordering diff.
SYSTEMS=(x86_64-linux aarch64-linux)
# Nix system -> the architecture slug Cider uses in its .deb filenames.
declare -A ARCHES=(
  [x86_64-linux]=x64
  [aarch64-linux]=arm64
)
# An update is only published when every system listed here has a .deb.
REQUIRED_SYSTEMS=(x86_64-linux)

# Resolve the repo root. Under `nix run .#update` the script itself lives in
# the store, so $0 is useless — prefer the git checkout we were invoked from.
if [ -n "${CIDER_FLAKE_ROOT:-}" ]; then
  repo_root=$CIDER_FLAKE_ROOT
elif repo_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$repo_root" ]; then
  :
else
  repo_root=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
fi

sources_file="$repo_root/pkgs/cider/sources.json"
if [ ! -f "$sources_file" ]; then
  echo "update.sh: $sources_file not found." >&2
  echo "update.sh: run this from a cider-flake checkout, or set CIDER_FLAKE_ROOT." >&2
  exit 1
fi

want_version=""
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version) want_version="${2:?--version needs an argument}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "update.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

emit() {
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >>"$GITHUB_OUTPUT"
  return 0
}

old_version=$(jq -r '.version' "$sources_file")

index=$(curl --fail --silent --show-error --location --retry 3 "$POOL_URL/")

# The pool is an nginx autoindex; every release shows up as a plain .deb link.
mapfile -t available < <(
  printf '%s' "$index" |
    grep -oE 'cider-v[0-9]+(\.[0-9]+)+-linux-(x64|arm64)\.deb' |
    sort -u
)
if [ ${#available[@]} -eq 0 ]; then
  echo "update.sh: found no .deb files at $POOL_URL/ — did the layout change?" >&2
  exit 1
fi

has_deb() { # version, debArch
  printf '%s\n' "${available[@]}" | grep -qxF "cider-v$1-linux-$2.deb"
}

if [ -n "$want_version" ]; then
  new_version="$want_version"
else
  # Newest version that covers every required system, newest candidate first.
  new_version=""
  while read -r candidate; do
    complete=true
    for system in "${REQUIRED_SYSTEMS[@]}"; do
      has_deb "$candidate" "${ARCHES[$system]}" || complete=false
    done
    if $complete; then new_version="$candidate"; break; fi
  done < <(
    printf '%s\n' "${available[@]}" |
      sed -E 's/^cider-v(.+)-linux-(x64|arm64)\.deb$/\1/' |
      sort -uV -r
  )
fi

if [ -z "$new_version" ]; then
  echo "update.sh: no version in the pool has a .deb for ${REQUIRED_SYSTEMS[*]}" >&2
  exit 1
fi

emit "old-version=$old_version"
emit "version=$new_version"
emit "changelog=https://cider.sh/changelogs/$new_version"

if [ "$old_version" = "$new_version" ]; then
  echo "update.sh: already on $new_version"
  emit "updated=false"
  exit 0
fi

echo "update.sh: $old_version -> $new_version"
if $dry_run; then
  emit "updated=true"
  echo "update.sh: --dry-run, not writing $sources_file"
  exit 0
fi

# Prefetch each architecture that exists for this version. Missing arches are
# dropped from sources.json rather than guessed, so meta.platforms stays honest.
platforms_json="{}"
for system in "${SYSTEMS[@]}"; do
  deb_arch="${ARCHES[$system]}"
  url="$POOL_URL/cider-v$new_version-linux-$deb_arch.deb"

  if ! has_deb "$new_version" "$deb_arch"; then
    echo "update.sh: no $deb_arch build for $new_version, skipping $system" >&2
    continue
  fi

  echo "update.sh: prefetching $system ($deb_arch)..."
  hash=$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r '.hash')
  echo "update.sh:   $hash"

  platforms_json=$(
    jq --arg sys "$system" --arg arch "$deb_arch" --arg hash "$hash" \
      '.[$sys] = { debArch: $arch, hash: $hash }' <<<"$platforms_json"
  )
done

jq --arg version "$new_version" --argjson platforms "$platforms_json" \
  '.version = $version | .platforms = $platforms' \
  "$sources_file" >"$sources_file.tmp"
mv "$sources_file.tmp" "$sources_file"

emit "updated=true"
emit "systems=$(jq -r '.platforms | keys | join(",")' "$sources_file")"
echo "update.sh: wrote $sources_file"
