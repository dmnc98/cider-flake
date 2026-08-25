{ lib
, appimageTools
, fetchurl
, src ? null
, url ? null
, sha256 ? null
, hash ? null
, pname ? "cider"
, version ? "unstable"
}:

let
  haveSrc = src != null;
  haveRemote = url != null && (sha256 != null || hash != null);

  resolvedSrc =
    if haveSrc then src
    else if haveRemote then
      fetchurl ({
        inherit url;
        name = "${pname}-${version}-linux.AppImage";
      } // (if hash != null then { inherit hash; } else { inherit sha256; }))
    else throw ''
      cider: no source supplied.

      Cider is gated behind https://taproom.cider.sh (Cloudflare-protected) and
      cannot be downloaded from inside a Nix build sandbox. Sign in with your
      browser, download the Linux AppImage once, then point this package at it:

        # Option A: local path
        services or programs.cider.source = /etc/nixos/cider/cider-linux-x64.AppImage;

        # Option B: a self-hosted mirror (or any reachable URL)
        programs.cider.url    = "https://example.invalid/cider-linux-x64.AppImage";
        programs.cider.sha256 = "<sri or base32 hash>";

      Or, when calling lib.mkCider directly:
        lib.mkCider pkgs { src = ./cider-linux-x64.AppImage; }
    '';

  contents = appimageTools.extract {
    inherit pname version;
    src = resolvedSrc;
  };
in
appimageTools.wrapType2 {
  inherit pname version;
  src = resolvedSrc;

  extraPkgs = pkgs: with pkgs; [
    libsecret
    libnotify
  ];

  extraInstallCommands = ''
    mkdir -p $out/share/applications $out/share/pixmaps

    for f in ${contents}/*.desktop; do
      [ -e "$f" ] || continue
      install -m 444 "$f" "$out/share/applications/$(basename "$f")"
    done

    if [ -d ${contents}/usr/share/icons ]; then
      cp -r ${contents}/usr/share/icons $out/share/
      chmod -R u+w $out/share/icons
    fi
    for f in ${contents}/*.png; do
      [ -e "$f" ] || continue
      install -Dm 444 "$f" "$out/share/pixmaps/$(basename "$f")"
    done

    # Normalise icon basenames to match ${pname} so Icon=${pname} resolves.
    for f in $out/share/pixmaps/*.png; do
      [ -e "$f" ] || continue
      mv -n "$f" "$out/share/pixmaps/${pname}.png" || true
    done
    if [ -d $out/share/icons ]; then
      find $out/share/icons -name '*.png' | while read -r f; do
        mv -n "$f" "$(dirname "$f")/${pname}.png" || true
      done
    fi

    # Rewrite the main Exec/Icon entries to the wrapper name without touching
    # Desktop Action Exec lines (dbus-send ...).
    for d in $out/share/applications/*.desktop; do
      [ -e "$d" ] || continue
      sed -i \
        -e "s|^Exec=AppRun|Exec=${pname}|" \
        -e "s|^Exec=Cider|Exec=${pname}|" \
        -e "s|^Exec=cider|Exec=${pname}|" \
        -e "s|^Icon=Cider$|Icon=${pname}|" \
        -e "s|^Icon=cider$|Icon=${pname}|" \
        "$d"
    done
  '';

  meta = with lib; {
    description = "Cross-platform Apple Music client (Taproom AppImage build)";
    homepage = "https://cider.sh";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = pname;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
