{
  description = "macOS multilingual Neovim motions backed by Apple NaturalLanguage";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" ];
      forDarwin = nixpkgs.lib.genAttrs systems;
    in {
      packages = forDarwin (system:
        let
          pkgs = import nixpkgs { inherit system; };
          helper = pkgs.stdenv.mkDerivation {
            pname = "lingua-motion-helper";
            version = "1.0.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.swift ];
            buildPhase = ''
              # Locked nixpkgs provides Swift 5.10.1; host Swift 6 is authoritative.
              swiftc -swift-version 5 -warnings-as-errors -strict-concurrency=complete -O \
                -framework Foundation -framework NaturalLanguage \
                Sources/lingua-motion-helper/main.swift -o lingua-motion-helper
            '';
            installPhase = ''
              install -Dm755 lingua-motion-helper $out/bin/lingua-motion-helper
            '';
            meta.platforms = pkgs.lib.platforms.darwin;
          };
          vimPlugin = pkgs.stdenvNoCC.mkDerivation {
            pname = "lingua-motion.nvim";
            version = "1.0.0";
            src = ./.;
            dontBuild = true;
            forceShare = [ "man" "info" ];
            installPhase = ''
              mkdir -p $out
              cp -R lua $out/
              cp -R doc $out/
            '';
            passthru.helper = helper;
          };
        in {
          "lingua-motion-helper" = helper;
          lingua-motion = vimPlugin;
          default = vimPlugin;
        });

      checks = forDarwin (system:
        let
          pkgs = import nixpkgs { inherit system; };
          staticChecks = pkgs.stdenv.mkDerivation {
            pname = "lingua-motion-static-checks";
            version = "1.0.0";
            src = ./.;
            nativeBuildInputs = [
              pkgs.python3
              pkgs.pyright
              pkgs.ruff
              pkgs.swift
              pkgs.swift-format
              pkgs.swiftlint
              pkgs.stylua
              pkgs.lua-language-server
              pkgs.neovim
            ];
            buildPhase = ''
              cp -R . $TMPDIR/lingua-motion-static
              cd $TMPDIR/lingua-motion-static
              # SwiftLint in nixpkgs lacks sourcekitdInProc.framework.
              LUA_LS_META=${pkgs.lua-language-server}/share/lua-language-server/meta \
                LINGUA_MOTION_SWIFT_VERSION=5 LINGUA_MOTION_DISABLE_SOURCEKIT=1 tests/lint.sh
            '';
            installPhase = "touch $out";
          };
          tests = pkgs.stdenv.mkDerivation {
            pname = "lingua-motion-tests";
            version = "1.0.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.swift pkgs.neovim pkgs.python3 ];
            buildPhase = ''
              cp -R . $TMPDIR/lingua-motion
              cd $TMPDIR/lingua-motion
              # Locked nixpkgs provides Swift 5.10.1; host Swift 6 is authoritative.
              LINGUA_MOTION_SWIFT_VERSION=5 LINGUA_MOTION_SKIP_RSS=1 tests/run.sh
            '';
            installPhase = "touch $out";
          };
          packageContents = pkgs.runCommand "lingua-motion-package-contents" { } ''
            test -f ${self.packages.${system}.lingua-motion}/lua/lingua_motion/init.lua
            test -f ${self.packages.${system}.lingua-motion}/doc/lingua-motion.txt
            touch $out
          '';
        in {
          "lingua-motion-helper" = self.packages.${system}."lingua-motion-helper";
          lingua-motion = self.packages.${system}.lingua-motion;
          lingua-motion-static-checks = staticChecks;
          lingua-motion-tests = tests;
          lingua-motion-package-contents = packageContents;
        });
    };
}
