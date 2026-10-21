{
  description = "Cider 4 (Apple Music client) packaged for NixOS from Cider Collective's public APT repository.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      sources = builtins.fromJSON (builtins.readFile ./pkgs/cider/sources.json);

      # Systems Cider itself ships a .deb for.
      ciderSystems = builtins.attrNames sources.platforms;
      # Systems this flake's dev shell / scripts are available on.
      devSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forSystems =
        systems: f:
        nixpkgs.lib.genAttrs systems (
          system:
          f system (
            import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            }
          )
        );

      updateDeps = pkgs: [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
      ];
    in
    {
      lib.mkCider = pkgs: args: pkgs.callPackage ./pkgs/cider/package.nix args;

      overlays.default = final: _prev: {
        cider = final.callPackage ./pkgs/cider/package.nix { };
      };

      nixosModules.default = import ./modules/nixos.nix self;
      nixosModules.cider = self.nixosModules.default;

      homeManagerModules.default = import ./modules/home-manager.nix self;
      homeManagerModules.cider = self.homeManagerModules.default;

      packages = forSystems ciderSystems (
        _system: pkgs: rec {
          cider = pkgs.callPackage ./pkgs/cider/package.nix { };
          default = cider;
        }
      );

      checks = forSystems ciderSystems (
        system: _pkgs: {
          cider = self.packages.${system}.cider;
          cider-startup = self.packages.${system}.cider.tests.startup;
        }
      );

      apps = forSystems devSystems (
        system: pkgs: {
          # `nix run .#update` — bump pkgs/cider/sources.json to the newest
          # release in Cider's public pool. This is what CI runs.
          update = {
            type = "app";
            meta.description = "Bump pkgs/cider/sources.json to the latest Cider release";
            program = toString (
              pkgs.writeShellScript "cider-update" ''
                export PATH=${nixpkgs.lib.makeBinPath (updateDeps pkgs)}:$PATH
                exec ${./scripts/update.sh} "$@"
              ''
            );
          };

          # `nix run .#hash -- 4.0.16` — SRI hashes for an arbitrary version,
          # for pinning a build other than the one this flake tracks.
          hash = {
            type = "app";
            meta.description = "Print SRI hashes of a given Cider version's .deb files";
            program = toString (
              pkgs.writeShellScript "cider-hash" ''
                set -eu
                export PATH=${nixpkgs.lib.makeBinPath (updateDeps pkgs)}:$PATH
                if [ $# -ne 1 ]; then
                  echo "usage: nix run .#hash -- <version>   (e.g. 4.0.17)" >&2
                  exit 64
                fi
                for pair in x86_64-linux:x64 aarch64-linux:arm64; do
                  system=''${pair%%:*}
                  arch=''${pair##*:}
                  url="https://repo.cider.sh/apt/pool/main/cider-v$1-linux-$arch.deb"
                  if ! curl -fsI "$url" >/dev/null 2>&1; then
                    echo "$system	(no $arch build for $1)"
                    continue
                  fi
                  printf '%s\t%s\n' "$system" \
                    "$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"
                done
              ''
            );
          };

          default = self.apps.${system}.update;
        }
      );

      devShells = forSystems devSystems (
        _system: pkgs: {
          default = pkgs.mkShellNoCC {
            packages = updateDeps pkgs ++ [
              pkgs.nixfmt
              pkgs.shellcheck
            ];
          };
        }
      );

      formatter = forSystems devSystems (_system: pkgs: pkgs.nixfmt);
    };
}
