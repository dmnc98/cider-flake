# cider-flake

A Nix flake that packages [Cider](https://cider.sh) 4 — the proprietary Apple
Music client — straight from Cider Collective's **public** Linux repository, and
exposes it as a package, an overlay, a NixOS module and a Home Manager module.

A bot watches upstream and republishes this flake whenever Cider ships a new
version, so `nix flake update` is all you need to upgrade.

```nix
programs.cider.enable = true;   # that's it
```

## What changed, and why this flake got simpler

Cider used to be download-gated: every build lived behind
[Taproom](https://taproom.cider.sh), which is Cloudflare-challenged and
account-bound, so `fetchurl` inside the Nix sandbox could never reach it. The
old version of this flake therefore refused to download anything — you fetched
the AppImage in a browser and pointed the flake at the file.

Cider has since inverted that model. The Linux build is now published openly at
**<https://repo.cider.sh>** (an APT pool plus an RPM tree), and the paywall moved
*after* installation: you install freely and enter a license inside the app.
Nothing in the download path is authenticated any more.

That means this flake can do what a flake should — fetch, pin and build by
itself. The `source` / `url` + `sha256` dance is gone.

> Cider is still proprietary and still needs a paid license plus an active Apple
> Music subscription. This flake only repackages the openly published binary; it
> does not circumvent licensing, and it ships no credentials.

## Install

Add the input:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cider.url = "github:dmnc98/cider-flake";
    cider.inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

### NixOS

```nix
# configuration.nix
{ inputs, ... }:
{
  imports = [ inputs.cider.nixosModules.default ];

  nixpkgs.config.allowUnfree = true;
  programs.cider.enable = true;
}
```

### Home Manager

```nix
# home.nix
{ inputs, ... }:
{
  imports = [ inputs.cider.homeManagerModules.default ];

  nixpkgs.config.allowUnfree = true;
  programs.cider.enable = true;
}
```

### Without a module

```nix
# via the overlay
nixpkgs.overlays = [ inputs.cider.overlays.default ];
environment.systemPackages = [ pkgs.cider ];
```

```nix
# or directly
environment.systemPackages = [ inputs.cider.packages.${pkgs.system}.cider ];
```

### Just try it

```sh
nix run github:dmnc98/cider-flake
```

## Module options

| Option | Type | Default | Notes |
| --- | --- | --- | --- |
| `programs.cider.enable` | `bool` | `false` | Adds Cider to `environment.systemPackages` / `home.packages`. |
| `programs.cider.version` | `str` | the pinned version | Any version still in the upstream pool. Needs `hash` if it isn't the pinned one. |
| `programs.cider.hash` | `str \| null` | `null` | SRI hash of the `.deb`. Only for overriding `version` or `url`. |
| `programs.cider.url` | `str \| null` | `null` | Fetch the `.deb` from a mirror instead. Requires `hash`. |
| `programs.cider.src` | `path \| null` | `null` | Use a `.deb` already on disk. Wins over `version`/`url`. |
| `programs.cider.disableSandbox` | `bool` | `true` | Passes `--no-sandbox --disable-gpu-sandbox`. See [Sandboxing](#sandboxing). |
| `programs.cider.package` | `package` | derived | Override to swap the package wholesale. |

Pinning an older release:

```sh
nix run github:dmnc98/cider-flake#hash -- 4.0.16
# x86_64-linux   sha256-…
# aarch64-linux  sha256-…
```

```nix
programs.cider.version = "4.0.16";
programs.cider.hash = "sha256-…";   # the one matching your system
```

## How the package is built

Cider's `.deb` is a stock electron-builder bundle, so the derivation follows the
nixpkgs convention for prebuilt Electron apps:

- `dpkg-deb` unpacks it; `usr/lib/cider` and `usr/share` move into `$out`.
- `autoPatchelfHook` rewrites the bundled Electron against nixpkgs' `gtk3`,
  `nss`, `alsa-lib`, `libgbm`, `libsecret` and `libnotify`.
- `libGL` goes in via `appendRunpaths` rather than `runtimeDependencies`, because
  ANGLE `dlopen`s `libEGL.so.1` from inside `libGLESv2.so` — a shared library,
  whose RPATH `runtimeDependencies` does not touch.
- `makeWrapper` adds the GTK/GSettings/dconf environment and Wayland flags
  gated on `NIXOS_OZONE_WL`.
- The shipped `cider.desktop` already says `Exec=cider` / `Icon=cider`, which
  matches the wrapper, so only the icon is relocated into `hicolor`.

`nix build .#checks.<system>.cider-startup` asserts that no shared library is
left unresolved after patching.

### Sandboxing

The `.deb` ships `chrome-sandbox`, Electron's setuid sandbox helper. A Nix store
path can never be setuid root, and Electron refuses to start when the helper is
present but misconfigured — so the wrapper passes `--no-sandbox
--disable-gpu-sandbox` by default.

If you'd rather keep Chromium's sandbox, set `programs.cider.disableSandbox =
false` and arrange a setuid helper yourself (e.g. via
`security.chromiumSuidSandbox.enable`). Cider will not launch with the default
store-path helper otherwise.

### Licensing Cider

Install, launch Cider, and sign in. If the Taproom OAuth flow misbehaves on
Linux, copy a key from <https://taproom.cider.sh/licenses> and use **Enter
Taproom Token Manually**. The package bundles `libsecret`, so the token persists
in your desktop keyring.

## The publishing cycle

`pkgs/cider/sources.json` is the single source of truth — a version plus one SRI
hash per system. Everything else derives from it, including `meta.platforms` and
`meta.changelog`.

```json
{
  "version": "4.0.17",
  "urlTemplate": "https://repo.cider.sh/apt/pool/main/cider-v@version@-linux-@debArch@.deb",
  "platforms": {
    "x86_64-linux": { "debArch": "x64",   "hash": "sha256-…" },
    "aarch64-linux": { "debArch": "arm64", "hash": "sha256-…" }
  }
}
```

### `.github/workflows/update.yml`

Runs every six hours, and on demand. Three gated jobs:

1. **discover** — scrapes the nginx autoindex at
   <https://repo.cider.sh/apt/pool/main/>, picks the highest version (`sort -V`,
   so `4.0.9.1` sorts correctly) that has an `x86_64` build, prefetches an SRI
   hash for every architecture that exists for it, and rewrites
   `sources.json`. Architectures without a `.deb` are dropped rather than
   guessed, so `meta.platforms` never lies. If the pin is already current it
   emits `updated=false` and the run stops here.
2. **build** — the rewritten pin is built for real on `ubuntu-24.04` *and*
   `ubuntu-24.04-arm`, then the output tree is asserted (wrapper is executable,
   desktop file and icon are in place, no unresolved libraries).
3. **publish** — only now does it commit `cider: <old> -> <new>` to `main`, then
   hand off to `scripts/release.sh` to tag and release it.

So a version that doesn't build never reaches `main`, and consumers can pin
either a tag or `main`.

Manual dispatch takes three inputs: `version` (pin a specific release),
`force` (rebuild/republish the current pin) and `dry_run` (discover and build,
publish nothing).

**What the bot needs from the repository:**

- `ubuntu-24.04-arm` runners, which are free for public repositories only. On a
  private repo, either add a paid ARM runner or drop `aarch64-linux` from the
  matrix and from `SYSTEMS` in `scripts/update.sh`.
- No branch protection or ruleset on `main` that would reject a push from
  `GITHUB_TOKEN`. The default workflow permission can stay read-only — the
  publish job requests `contents: write` for itself.
- Note that a push made with `GITHUB_TOKEN` deliberately does not trigger other
  workflows, so `ci.yml` does not re-run on the bot's own commits. The update
  workflow has already built them.

### Tags

Tags track Cider's own version, with a `v` prefix — Cider 4.0.17 is `v4.0.17`.
Each one carries a GitHub release linking that version's upstream changelog, so
a tag is a pin you can point an input at:

```nix
inputs.cider.url = "github:dmnc98/cider-flake/v4.0.17";
```

`scripts/release.sh` creates them, and is idempotent — it never moves an
existing tag and never rewrites an existing release, so it is safe to run on
every push:

```sh
nix run .#release                 # create the local tag only
nix run .#release -- --push       # also push it and cut the release
nix run .#release -- --dry-run    # report what it would do
nix run .#release -- --ref <rev>  # tag <rev> instead of HEAD
```

Two workflows call it, because one cannot cover both cases:

- **`update.yml`** tags its own bumps directly, since a push made with
  `GITHUB_TOKEN` deliberately does not trigger other workflows.
- **`tag.yml`** covers pins that change by hand. It runs on every push to
  `main` — since the script is idempotent, that costs nothing when the tag
  already exists, and it means a pinned version that somehow has no tag gets
  one on the next push rather than waiting for the pin to change.

A tag marks the commit that *first* packaged that Cider version, so it falls
behind `main` as soon as anything else lands — that is normal, and `release.sh`
only ever asks whether the tag exists, never whether it matches `HEAD`. It
never moves or rewrites one. If a tag turns out not to be an ancestor of `main`
(a rolled-back pin, a force push) it says so and carries on, since the tag is
still a truthful record of where that version was first packaged.

### `.github/workflows/ci.yml`

Runs on every push and PR: formatting, `shellcheck`, `nix flake show
--all-systems`, dry-runs of the updater (which fails loudly if upstream changes
its layout) and of the release script, real builds on both architectures, and an
evaluation of both modules.

### Doing it by hand

```sh
nix run .#update              # bump sources.json to the newest release
nix run .#update -- --dry-run # report only
nix run .#update -- --version 4.0.16
```

It rewrites `sources.json` in the checkout it is run from (found via `git
rev-parse`, overridable with `CIDER_FLAKE_ROOT`), and it is byte-stable:
re-running it on an up-to-date tree produces no diff.

## Flake outputs

| Output | |
| --- | --- |
| `packages.<system>.cider` / `.default` | the wrapped Cider |
| `checks.<system>.cider`, `.cider-startup` | build + unresolved-library check |
| `apps.<system>.update` | bump `sources.json` (needs a checkout) |
| `apps.<system>.release` | tag the pinned version, cut its release |
| `apps.<system>.hash` | print SRI hashes for a given version |
| `nixosModules.default` / `.cider` | `programs.cider.*` for NixOS |
| `homeManagerModules.default` / `.cider` | `programs.cider.*` for Home Manager |
| `overlays.default` | adds `pkgs.cider` |
| `lib.mkCider` | `pkgs -> args -> derivation`, for full control |
| `devShells.default`, `formatter` | updater deps, `nixfmt` |

`x86_64-linux` and `aarch64-linux` are packaged; the apps and dev shell also
evaluate on Darwin so you can run the updater from a Mac.

## Notes and limitations

- Unfree, so `nixpkgs.config.allowUnfree = true` is required.
- Upstream's APT `Packages` index is currently empty — only the pool itself is
  populated. The updater therefore reads the directory listing, not the index.
  If Cider ever fixes the index, switching to it would be strictly better.
- The pool lags the storefronts: cider.sh may advertise a version that
  `repo.cider.sh` hasn't published yet. The bot tracks the pool, which is the
  only publicly fetchable source.
- `aarch64` builds exist from 4.0.16 onward; earlier versions are `x86_64`-only.
- Cider ignores `--version` and simply launches, so the startup check inspects
  the linker rather than running the binary.

## Acknowledgements

- [Cider Collective](https://cider.sh) for the client, and for opening up the
  Linux download.
- nixpkgs' [`cider-2`](https://github.com/NixOS/nixpkgs/tree/master/pkgs/by-name/ci/cider-2)
  package and [`ciderapp/sh.cider.Cider`](https://github.com/ciderapp/sh.cider.Cider)
  Flatpak manifest, which independently confirmed the `.deb` layout and the
  `libGL` / sandbox quirks.
