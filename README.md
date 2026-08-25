# cider-flake

A Nix flake that packages [Cider](https://cider.sh) (Apple Music client, v2+) from
its Linux AppImage and exposes it as a NixOS module and a Home Manager module.

## Why this flake doesn't download Cider for you

Cider 2/3/4 is distributed exclusively through https://taproom.cider.sh, which:

- Is fully behind Cloudflare's JS challenge — every endpoint returns HTTP 403
  to non-browser clients. The Nix sandbox has no JS engine, so `fetchurl` /
  `builtins.fetchurl` cannot get past it.
- Requires a Taproom account to authorise the download.
- Ships a proprietary client whose download API isn't publicly documented.

So this flake follows the standard NixOS pattern for gated binaries (NVIDIA
installers, Microsoft fonts, etc.): **you download the AppImage once from
Taproom in a browser, and the flake wraps it.**

## What you get

- `lib.mkCider` — a function `pkgs → args → derivation` that wraps an AppImage
  with `appimageTools.wrapType2`, adds `libsecret`/`libnotify` for the Taproom
  keyring, installs the `.desktop` file, and normalises icon names.
- `nixosModules.default` — adds `programs.cider.{enable,source,url,sha256,version}`.
- `homeManagerModules.default` — same options for per-user installs.
- `overlays.default` — exposes `pkgs.cider args` in any consumer.
- `apps.hash` — prints SRI and base32 SHA-256 of a downloaded AppImage.

## Picking a source: pure vs. `--impure`

Where you point `programs.cider.source` decides whether you need
`nixos-rebuild --impure`. Pick whichever fits how your config is laid out.

| Approach                              | Pure? | When to use                                                |
| ------------------------------------- | :---: | ---------------------------------------------------------- |
| 1. Relative path inside the flake     |  yes  | Your flake lives next to where you can drop the AppImage.  |
| 2. `path:` flake input                |  yes  | You want the binary outside your config tree but pinned.   |
| 3. `url` + `sha256`                   |  yes  | You self-host a mirror Nix can reach.                      |
| 4. Absolute path outside the flake    |  no   | Quick, but locks you into `--impure`.                      |

Absolute paths into `/nix/store/...` are also rejected in pure mode, so
`nix store add-path` then pinning the result **does not** dodge `--impure`.

## Quick start (NixOS) — pure, recommended

1. Sign in at https://taproom.cider.sh and download
   `cider-vX.Y.Z-linux-x64.AppImage`.

2. Put it **inside your flake's source tree**, e.g. `/etc/nixos/cider/`
   if your `flake.nix` is at `/etc/nixos/flake.nix`. Stage it with git so
   the flake sees it (`git add cider/cider-v4.0.0-linux-x64.AppImage`).

3. Add the flake to your system `flake.nix`:

   ```nix
   {
     inputs.nixpkgs.url   = "github:NixOS/nixpkgs/nixos-unstable";
     inputs.cider.url     = "path:/home/you/git/cider-flake";  # or github:you/cider-flake

     outputs = { self, nixpkgs, cider, ... }: {
       nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
         system = "x86_64-linux";
         modules = [
           ./configuration.nix
           cider.nixosModules.default
         ];
       };
     };
   }
   ```

4. In `configuration.nix` use a **relative path**:

   ```nix
   { ... }: {
     nixpkgs.config.allowUnfree = true;

     programs.cider.enable  = true;
     programs.cider.source  = ./cider/cider-v4.0.0-linux-x64.AppImage;
     programs.cider.version = "4.0.0";
   }
   ```

5. `sudo nixos-rebuild switch` — no `--impure` needed.

### Approach 2: `path:` flake input (binary outside the config tree)

If you don't want the 155 MB AppImage in your config repo, point a
`flake = false` input at a directory that contains it:

```nix
# your system flake.nix
inputs.cider-binary = {
  url   = "path:/var/lib/cider";   # directory that contains the AppImage
  flake = false;
};

# configuration.nix
{ inputs, ... }: {
  programs.cider.source = "${inputs.cider-binary}/cider-v4.0.0-linux-x64.AppImage";
}
```

The directory is hashed into `flake.lock`, so eval stays pure. Re-run
`nix flake lock --update-input cider-binary` after dropping a new AppImage
in there.

### Approach 4: absolute path (requires `--impure`)

```nix
programs.cider.source = /etc/nixos/cider/cider-v4.0.0-linux-x64.AppImage;
# sudo nixos-rebuild switch --impure
```

Works, but pure mode will refuse it because the file lives outside the
flake's source tree.

## Quick start (Home Manager)

Same pure approaches apply — put the AppImage in your dotfiles flake or
use a `path:` input:

```nix
# home.nix
{ inputs, ... }: {
  imports = [ inputs.cider.homeManagerModules.default ];

  nixpkgs.config.allowUnfree = true;

  programs.cider.enable  = true;
  programs.cider.source  = ./cider/cider-v4.0.0-linux-x64.AppImage;  # inside the flake
  programs.cider.version = "4.0.0";
}
```

## Using a URL instead of a local path

If you mirror the AppImage on storage Nix can reach without a JS challenge
(your own server, S3 bucket, etc.):

```nix
programs.cider.url    = "https://my-mirror.example/cider-v4.0.0-linux-x64.AppImage";
programs.cider.sha256 = "sha256-mXiQvIXFeWQIzrILDKddq+b+hoE26SbSStDzaqQk+Z0=";
```

Compute the hash with the bundled helper:

```sh
nix run path:/home/you/git/cider-flake#hash -- ~/Downloads/cider-v4.0.0-linux-x64.AppImage
# sha256 (SRI):    sha256-mXiQvIXFeWQIzrILDKddq+b+hoE26SbSStDzaqQk+Z0=
# sha256 (base32): 17gr4jj6mwyh9b92ds9nh63gxrmbbnkhq2xjrq468yf5hny90y4r
```

Either format is accepted by `programs.cider.sha256`.

## Using it directly (no module)

```nix
{ pkgs, cider, ... }: {
  environment.systemPackages = [
    (cider.lib.mkCider pkgs {
      src     = /etc/nixos/cider/cider-v4.0.0-linux-x64.AppImage;
      version = "4.0.0";
    })
  ];
}
```

Or via the overlay:

```nix
nixpkgs.overlays = [ cider.overlays.default ];
environment.systemPackages = [
  (pkgs.cider { src = /etc/nixos/cider/cider-v4.0.0-linux-x64.AppImage; version = "4.0.0"; })
];
```

## Module options

| Option                 | Type           | Default      | Notes                                                          |
| ---------------------- | -------------- | ------------ | -------------------------------------------------------------- |
| `programs.cider.enable`  | `bool`         | `false`      | Adds Cider to `environment.systemPackages` / `home.packages`.  |
| `programs.cider.source`  | `path \| null` | `null`       | Local AppImage path. Mutually exclusive with `url`+`sha256`.   |
| `programs.cider.url`     | `str \| null`  | `null`       | URL of the AppImage. Requires `sha256`.                        |
| `programs.cider.sha256`  | `str \| null`  | `null`       | SRI (`sha256-…`) or base32 hash of the file at `url`.          |
| `programs.cider.version` | `str`          | `"unstable"` | Cosmetic version label baked into the derivation name.         |
| `programs.cider.package` | `package`      | derived      | Read-only; the resulting wrapped derivation.                   |

You must set either `source` **or** both `url` and `sha256`; otherwise the
assertion (or, if forced, the `mkCider` throw) tells you what's missing.

## Signing in to Taproom

The OAuth/itch.io flow is broken on Linux
([ciderapp/Cider-2#1152](https://github.com/ciderapp/Cider-2/issues/1152)).
Workaround:

1. Log into https://taproom.cider.sh in a browser.
2. Copy a license key from https://taproom.cider.sh/licenses.
3. In Cider, choose **Enter Taproom Token Manually** and paste it.

The wrapper bundles `libsecret`, so the token persists in your desktop keyring.

## Upgrading

Each new Cider release is a new AppImage. Download it from Taproom, replace
the file (or update `url`+`sha256`), bump `programs.cider.version`, and
`nixos-rebuild switch`.

## Limitations

- `x86_64-linux` only (no Cider AppImage for `aarch64-linux` upstream).
- Marked unfree (`licenses.unfree`) — set `nixpkgs.config.allowUnfree = true;`.
- No automatic update channel; you upgrade by replacing the source.
- Sandboxing flags are inherited from the AppImage; if Electron complains
  about chrome-sandbox, run `cider --no-sandbox` once to confirm and report.

## Acknowledgements

- [Cider Collective](https://cider.sh) for the client.
- Nixpkgs' `appimageTools` (`wrapType2` + `extract`) does the heavy lifting.
