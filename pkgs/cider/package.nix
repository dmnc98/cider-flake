{
  lib,
  stdenv,
  fetchurl,
  runCommandLocal,
  dpkg,
  file,
  glibc,
  patchelf,
  autoPatchelfHook,
  makeShellWrapper,
  wrapGAppsHook3,
  gsettings-desktop-schemas,
  dconf,
  glib,

  # Needed by the bundled Electron runtime (autoPatchelfHook resolves these).
  alsa-lib,
  gtk3,
  libgbm,
  libGL,
  libnotify,
  libsecret,
  nspr,
  nss,

  # Source selection. By default everything is taken from ./sources.json, which
  # is what the update bot rewrites. Override any of these to pin a build by
  # hand (e.g. an older version, or a .deb you already have on disk).
  # `deb*` rather than the bare names `url`/`hash`/`src`, because callPackage
  # fills any argument that matches a top-level nixpkgs attribute — and
  # `pkgs.src` exists.
  sources ? lib.importJSON ./sources.json,
  version ? sources.version,
  debUrl ? null,
  debHash ? null,
  debFile ? null,

  # Pass `--no-sandbox` to Electron. The .deb ships a `chrome-sandbox` helper
  # that has to be setuid root, which a Nix store path can never be; without
  # this flag Electron refuses to start. Set to false if you instead enable
  # `security.chromiumSuidSandbox.enable` and wire up the helper yourself.
  disableSandbox ? true,
}:

let
  inherit (stdenv.hostPlatform) system;

  platform =
    sources.platforms.${system}
      or (throw "cider: unsupported system '${system}'; sources.json pins ${lib.concatStringsSep ", " (lib.attrNames sources.platforms)}");

  resolvedUrl =
    if debUrl != null then
      debUrl
    else
      builtins.replaceStrings [ "@version@" "@debArch@" ] [ version platform.debArch ]
        sources.urlTemplate;

  resolvedSrc =
    if debFile != null then
      debFile
    else
      fetchurl {
        url = resolvedUrl;
        hash = if debHash != null then debHash else platform.hash;
      };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "cider";
  inherit version;
  src = resolvedSrc;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    # Deliberately the *shell* wrapper, and invoked by its unambiguous name
    # below: wrapGAppsHook3 propagates makeBinaryWrapper, whose `makeWrapper`
    # shadows the shell one and would pass the conditional Wayland flags
    # through as literal text, since a C wrapper does no shell expansion.
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    glib
    gtk3
    libgbm
    libnotify
    libsecret
    nspr
    nss
  ];

  # `appendRunpaths` applies to every ELF including shared libraries;
  # `runtimeDependencies` only rewrites dynamic executables, which is not
  # enough for libraries that dlopen each other.
  appendRunpaths = lib.makeLibraryPath [
    libGL # libEGL.so.1 is dlopen'd at runtime, so it is never a DT_NEEDED entry
  ];

  # wrapGAppsHook3 is only here for its GDK_PIXBUF/GSettings setup; let it
  # collect the environment but do the actual wrapping ourselves below so the
  # binary is not wrapped twice.
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar --extract
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib $out/share
    cp -r usr/lib/* $out/lib/
    cp -r usr/share/* $out/share/

    chmod +x $out/lib/cider/Cider

    # Built as an array rather than an inline `lib.optionalString`, so that
    # disabling it leaves no stray blank continuation line behind.
    sandboxArgs=()
    ${lib.optionalString disableSandbox ''
      sandboxArgs+=(--add-flags "--no-sandbox --disable-gpu-sandbox")
    ''}

    makeShellWrapper $out/lib/cider/Cider $out/bin/cider \
      "''${gappsWrapperArgs[@]}" \
      "''${sandboxArgs[@]}" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}" \
      --prefix XDG_DATA_DIRS : "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}" \
      --prefix XDG_DATA_DIRS : "${gtk3}/share/gsettings-schemas/${gtk3.name}" \
      --prefix GIO_EXTRA_MODULES : "${dconf.lib}/lib/gio/modules"

    runHook postInstall
  '';

  postFixup = ''
    # Icon=cider / Exec=cider already match our wrapper name, so the desktop
    # file only needs to move out of the pixmaps-only icon lookup path.
    install -Dm444 $out/share/pixmaps/cider.png \
      $out/share/icons/hicolor/256x256/apps/cider.png

    # Tolerate absence: these are cosmetic, and a future .deb may drop them.
    rm -rf $out/share/lintian $out/share/doc

    # Unused desktop files and macOS/Windows icons shipped inside resources/.
    rm -f $out/lib/cider/resources/Cider.desktop \
          $out/lib/cider/resources/Cider.flatpak.desktop
    rm -f $out/lib/cider/resources/public/icon.icns \
          $out/lib/cider/resources/public/icon-osx-previous.icns \
          $out/lib/cider/resources/public/icon.ico
  '';

  passthru = {
    inherit sources;
    url = resolvedUrl;

    # `nix build .#checks.<system>.cider-startup` — the invariants that would
    # otherwise only show up as a blank window or a crash on first launch.
    tests.startup =
      runCommandLocal "cider-${version}-startup-test"
        {
          nativeBuildInputs = [
            glibc.bin # ldd
            file
            patchelf
          ];
          cider = finalAttrs.finalPackage;
        }
        ''
          set -euo pipefail
          fail=0

          echo "== every bundled ELF links completely =="
          while read -r elf; do
            if ldd "$elf" 2>/dev/null | grep -q 'not found'; then
              echo "FAIL: unresolved libraries in $elf" >&2
              ldd "$elf" | grep 'not found' >&2
              fail=1
            fi
          done < <(
            find "$cider/lib/cider" -type f -exec \
              sh -c 'file -b "$1" | grep -q "^ELF" && echo "$1"' _ {} \;
          )

          echo "== libEGL.so.1 is reachable from Cider's runpath =="
          # Not caught by autoPatchelfHook: ANGLE dlopen()s libEGL, so nothing
          # records it as a DT_NEEDED entry. appendRunpaths is what supplies it.
          egl_dir=
          for dir in $(patchelf --print-rpath "$cider/lib/cider/Cider" | tr ':' ' '); do
            if [ -e "$dir/libEGL.so.1" ]; then
              egl_dir=$dir
              break
            fi
          done
          if [ -n "$egl_dir" ]; then
            echo "   libEGL.so.1 <- $egl_dir"
          else
            echo "FAIL: libEGL.so.1 is not in Cider's runpath (lost appendRunpaths?)" >&2
            fail=1
          fi

          echo "== the installed tree is usable =="
          test -x "$cider/bin/cider"                                  || { echo "FAIL: no executable bin/cider" >&2; fail=1; }
          test -f "$cider/share/applications/cider.desktop"            || { echo "FAIL: no desktop file" >&2; fail=1; }
          test -f "$cider/share/icons/hicolor/256x256/apps/cider.png"  || { echo "FAIL: no hicolor icon" >&2; fail=1; }
          grep -qx 'Exec=cider %U' "$cider/share/applications/cider.desktop" \
            || { echo "FAIL: desktop Exec does not point at the wrapper" >&2; fail=1; }
          grep -qx 'Icon=cider' "$cider/share/applications/cider.desktop" \
            || { echo "FAIL: desktop Icon does not match the installed icon" >&2; fail=1; }

          echo "== bin/cider is a shell wrapper, so the ozone flags expand =="
          # makeBinaryWrapper, which wrapGAppsHook3 propagates, compiles the
          # wrapper to C and performs no shell expansion: the conditional
          # ''${NIXOS_OZONE_WL:+...} would reach Electron as literal text and
          # Cider would silently never get the Wayland flags.
          if head -n1 "$cider/bin/cider" | grep -q '^#!'; then
            grep -q 'NIXOS_OZONE_WL:+' "$cider/bin/cider" \
              || { echo "FAIL: the wrapper lost the NIXOS_OZONE_WL conditional" >&2; fail=1; }
          else
            echo "FAIL: bin/cider is not a shell wrapper (makeShellWrapper shadowed again?)" >&2
            fail=1
          fi

          echo "== the Electron bundle is intact =="
          # Cider ignores --version and just launches, so the binary is never
          # run here. These are the files Electron cannot start without. (The
          # `version` file holds Cider's internal build string, not the release
          # version — the release version is pinned by sources.json's hash.)
          for f in version resources.pak icudtl.dat resources/app.asar; do
            test -s "$cider/lib/cider/$f" \
              || { echo "FAIL: missing or empty lib/cider/$f" >&2; fail=1; }
          done

          [ "$fail" -eq 0 ] || exit 1
          echo OK | tee "$out"
        '';
  };

  meta = {
    description = "Cross-platform Apple Music client (requires a Cider license)";
    longDescription = ''
      Cider is a proprietary Apple Music client. Since Cider 4 the Linux build
      is published openly at https://repo.cider.sh, and the license is entered
      inside the app after installation rather than gating the download.
    '';
    homepage = "https://cider.sh";
    downloadPage = "https://cider.sh/downloads/client";
    changelog = "https://cider.sh/changelogs/${version}";
    license = lib.licenses.unfree;
    mainProgram = "cider";
    platforms = lib.attrNames sources.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
