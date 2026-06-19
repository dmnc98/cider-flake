{
  description = "Cider (Apple Music client) packaged for NixOS from a Taproom AppImage.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forSystems = f: nixpkgs.lib.genAttrs supportedSystems
        (system: f system (import nixpkgs { inherit system; config.allowUnfree = true; }));

      mkCider = pkgs: args: pkgs.callPackage ./cider.nix args;
    in
    {
      lib = { inherit mkCider; };

      overlays.default = final: _prev: {
        cider = args: mkCider final args;
      };

      nixosModules.default = import ./nixos-module.nix self;
      nixosModules.cider = self.nixosModules.default;

      homeManagerModules.default = import ./hm-module.nix self;
      homeManagerModules.cider = self.homeManagerModules.default;

      packages = forSystems (system: pkgs: {
        # No default `cider` package: a source must be supplied. See `lib.mkCider`
        # or the NixOS / Home Manager modules. `nix build .#default` prints help.
        default = pkgs.writeShellScriptBin "cider-flake-help" ''
          cat <<'EOF'
          This flake packages Cider from a Taproom AppImage. It cannot fetch
          the AppImage itself (Cloudflare blocks Nix sandbox fetches).

          Build it from your own flake / config like:

            # flake.nix
            inputs.cider.url = "path:/home/you/git/cider-flake";

            # configuration.nix (NixOS)
            imports = [ inputs.cider.nixosModules.default ];
            programs.cider.enable = true;
            programs.cider.source = /etc/nixos/cider/cider-linux-x64.AppImage;

            # home.nix (Home Manager)
            imports = [ inputs.cider.homeManagerModules.default ];
            programs.cider.enable = true;
            programs.cider.source = /home/you/cider/cider-linux-x64.AppImage;

          Compute a sha256 for the url+sha256 variant:
            nix run .#hash -- /path/to/cider-linux-x64.AppImage
          EOF
        '';
      });

      apps = forSystems (system: pkgs: {
        # Helper that prints the sha256 of a Cider AppImage you've already
        # downloaded, so you can paste it into the module config.
        hash = {
          type = "app";
          program = toString (pkgs.writeShellScript "cider-hash" ''
            set -eu
            if [ $# -ne 1 ]; then
              echo "usage: nix run .#hash -- /path/to/cider-linux-x64.AppImage" >&2
              exit 64
            fi
            sri=$(${pkgs.nix}/bin/nix --extra-experimental-features nix-command \
              hash file --type sha256 "$1")
            echo "sha256 (SRI):    $sri"
            echo "sha256 (base32): $(${pkgs.nix}/bin/nix --extra-experimental-features nix-command \
              hash convert --hash-algo sha256 --to nix32 "$sri")"
          '');
        };
      });
    };
}
