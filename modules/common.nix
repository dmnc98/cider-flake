# Shared option set for the NixOS and Home Manager modules. `install` says
# where the package ends up, which is the only thing that differs between them.
{ self, install }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.cider;
  sources = lib.importJSON ../pkgs/cider/sources.json;
in
{
  options.programs.cider = {
    enable = lib.mkEnableOption "Cider, a proprietary Apple Music client";

    version = lib.mkOption {
      type = lib.types.str;
      default = sources.version;
      defaultText = lib.literalExpression "the version pinned in this flake";
      example = "4.0.16";
      description = ''
        Cider version to install. Any version still present in
        <https://repo.cider.sh/apt/pool/main/> works, but anything other than
        the pinned default also needs {option}`programs.cider.hash`.
      '';
    };

    hash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sha256-CanpS0yydWOkGKp/8SIVSJ7EavFUs9xBxUgmL9AUXJU=";
      description = ''
        SRI hash of the `.deb` for {option}`programs.cider.version`. Only
        needed when overriding the pinned version. Get it with
        `nix run github:dmnc98/cider-flake#hash -- <version>`.
      '';
    };

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://mirror.example/cider-v4.0.17-linux-x64.deb";
      description = ''
        Fetch the `.deb` from somewhere other than repo.cider.sh (a mirror, a
        supporter build). Requires {option}`programs.cider.hash`.
      '';
    };

    src = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./cider-v4.0.17-linux-x64.deb";
      description = ''
        Use a `.deb` already on disk instead of downloading one. Takes
        precedence over {option}`programs.cider.url` and
        {option}`programs.cider.version`.
      '';
    };

    disableSandbox = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Launch Cider with `--no-sandbox --disable-gpu-sandbox`. Electron's
        setuid sandbox helper cannot work from a read-only store path, so
        without this Cider refuses to start.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "The Cider package to install.";
      default = pkgs.callPackage "${self}/pkgs/cider/package.nix" {
        inherit (cfg) version disableSandbox;
        debUrl = cfg.url;
        debHash = cfg.hash;
        debFile = cfg.src;
      };
      defaultText = lib.literalExpression "cider built from the options above";
    };
  };

  config = lib.mkIf cfg.enable (
    {
      assertions = [
        {
          assertion = cfg.url == null || cfg.hash != null;
          message = "programs.cider.url requires programs.cider.hash.";
        }
        {
          assertion = cfg.version == sources.version || cfg.hash != null || cfg.src != null;
          message = ''
            programs.cider.version is pinned to "${cfg.version}" but this flake
            only knows the hash for "${sources.version}". Set
            programs.cider.hash as well, or update the flake input.
          '';
        }
      ];
    }
    // install cfg
  );
}
