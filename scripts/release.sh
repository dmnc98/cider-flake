#!/usr/bin/env bash
# Tag the Cider version currently pinned in pkgs/cider/sources.json, and cut a
# matching GitHub release. Tags track Cider's own version: 4.0.17 -> v4.0.17.
#
# Idempotent by design — safe to run on every push. An existing tag is never
# moved, and an existing release is never rewritten.
#
#   ./scripts/release.sh                 # create the local tag only
#   ./scripts/release.sh --push          # also push it and cut the release
#   ./scripts/release.sh --dry-run       # report what it would do
#   ./scripts/release.sh --ref <rev>     # tag <rev> instead of HEAD
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

push=false
dry_run=false
ref=HEAD
while [ $# -gt 0 ]; do
  case "$1" in
    --push) push=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    --ref) ref="${2:?--ref needs an argument}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release.sh: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

# Fail before doing anything if the tools the chosen mode needs are missing,
# rather than half-way through with "gh: command not found".
missing=()
for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if $push; then
  command -v gh >/dev/null 2>&1 || missing+=(gh)
fi
if [ ${#missing[@]} -gt 0 ]; then
  echo "release.sh: missing required tool(s): ${missing[*]}" >&2
  echo "release.sh: run it as \`nix run .#release\`, which provides them." >&2
  exit 1
fi

sources_file=$(find_sources_file)
repo_root=${sources_file%/"$SOURCES_REL"}
cd "$repo_root"

version=$(jq -r '.version' "$sources_file")
systems=$(jq -r '.platforms | keys | join(", ")' "$sources_file")
tag=$(version_tag "$version")
changelog="https://cider.sh/changelogs/$version"
sha=$(git rev-parse --verify "$ref")

emit "version=$version"
emit "tag=$tag"

# --- what already exists? ---------------------------------------------------

tag_local=false
git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 && tag_local=true

tag_remote=false
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  tag_remote=true
fi

release_exists=false
if $push && gh release view "$tag" >/dev/null 2>&1; then
  release_exists=true
fi

# A tag marks the commit that first packaged this Cider version, so once main
# moves on the tag legitimately lags HEAD — forever. The only question here is
# whether the tag exists at all; comparing it against HEAD would fail on every
# later push.
if $tag_local || $tag_remote; then
  if $tag_local; then
    tagged_sha=$(git rev-parse -q --verify "refs/tags/$tag^{commit}")
    # Not an ancestor means something unusual (a rolled-back pin, a force
    # push), worth saying out loud — but not worth failing over, since the tag
    # is still a truthful record of where that version was first packaged.
    if ! git merge-base --is-ancestor "$tagged_sha" "$sha" 2>/dev/null; then
      echo "release.sh: note: $tag points at $tagged_sha, which is not an ancestor of $sha." >&2
      echo "release.sh: note: leaving it alone. Delete the tag if it really should move." >&2
    fi
  fi

  if ! $push || { $tag_remote && $release_exists; }; then
    echo "release.sh: $tag is already published, nothing to do"
    emit "created=false"
    exit 0
  fi

  # Tag exists but is not fully published yet: finish the job below without
  # creating or moving anything.
  echo "release.sh: $tag exists; reconciling remote tag and release"
else
  echo "release.sh: $tag -> $sha (systems: $systems)"
fi

if $dry_run; then
  { $tag_local || $tag_remote; } || echo "release.sh: would create tag $tag"
  if $push; then
    $tag_remote     || echo "release.sh: would push $tag to origin"
    $release_exists || echo "release.sh: would create release $tag"
  fi
  emit "created=true"
  exit 0
fi

# --- tag --------------------------------------------------------------------

if ! $tag_local && ! $tag_remote; then
  # Annotated tags need an identity; fall back to the Actions bot in CI.
  tag_args=()
  if ! git config user.email >/dev/null; then
    tag_args=(
      -c user.name="github-actions[bot]"
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com"
    )
  fi
  git "${tag_args[@]}" tag -a "$tag" "$sha" -m "cider $version"
  echo "release.sh: created tag $tag"
fi

if ! $push; then
  echo "release.sh: --push not given; tag is local only"
  emit "created=true"
  exit 0
fi

if ! $tag_remote; then
  git push origin "refs/tags/$tag"
  echo "release.sh: pushed $tag"
fi

# --- release ----------------------------------------------------------------

if $release_exists; then
  echo "release.sh: release $tag already exists"
  emit "created=true"
  exit 0
fi

repo_slug=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}

notes=$(
  cat <<EOM
Packages **Cider $version**, pinned from Cider Collective's public APT pool at
[repo.cider.sh](https://repo.cider.sh/apt/pool/main/).

- Upstream changelog: $changelog
- Systems: \`$systems\`

Cider is proprietary. This flake only repackages the openly published Linux
build — you still enter your own license inside the app after installing it.

\`\`\`nix
inputs.cider.url = "github:$repo_slug/$tag";
\`\`\`
EOM
)

gh release create "$tag" --title "Cider $version" --notes "$notes"
echo "release.sh: created release $tag"
emit "created=true"
