self: { config, lib, pkgs, ... }:

let
  cfg = config.programs.cider;
in
{
  options.programs.cider = {
    enable = lib.mkEnableOption "Cider Apple Music client (Taproom AppImage)";

    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "/home/alice/cider/cider-linux-x64.AppImage";
      description = ''
        Local path to a Cider Linux AppImage downloaded out-of-band from
        https://taproom.cider.sh. Mutually exclusive with `url`/`sha256`.
      '';
    };

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "URL of a Cider AppImage. Requires `sha256`.";
    };

    sha256 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SRI or base32 SHA-256 hash of the AppImage at `url`.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "unstable";
      description = "Cosmetic version label.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The computed Cider package.";
      default = self.lib.mkCider pkgs {
        inherit (cfg) url sha256 version;
        src = cfg.source;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.source != null || (cfg.url != null && cfg.sha256 != null);
      message = ''
        programs.cider.enable = true requires a source. Set either:
          programs.cider.source = /path/to/cider-linux-x64.AppImage;
        or:
          programs.cider.url    = "https://.../cider-linux-x64.AppImage";
          programs.cider.sha256 = "...";
      '';
    }];

    home.packages = [ cfg.package ];
  };
}
