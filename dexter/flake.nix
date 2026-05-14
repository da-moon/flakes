{
  description = "Dexter - AI agent for deep financial research";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "dexter";
        version = "2026.5.9";
        rev = "v2026.5.9";

        src = pkgs.fetchFromGitHub {
          owner = "virattt";
          repo = "dexter";
          inherit rev;
          hash = "sha256-htHfT+U0WO20+vDuOXnPqcS2YsZ5Y9EmeL9iaMswxgg=";
        };

        outputHashBySystem = {
          "aarch64-linux" = pkgs.lib.fakeHash;
          "x86_64-linux" = "sha256-p+xETSUdSnn+MUPThJFW4Eycz/2DvdPjiUKGPX8/pO4=";
        };

        npmDeps = pkgs.stdenv.mkDerivation {
          name = "${pname}-${version}-npm-deps";
          inherit src;

          nativeBuildInputs = with pkgs; [
            nodejs_20
            cacert
          ];

          dontPatchShebangs = true;
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash =
            outputHashBySystem.${system} or (throw "Missing outputHashBySystem entry for system: ${system}");

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export XDG_CACHE_HOME=$TMPDIR/.cache
            export npm_config_cache=$TMPDIR/.npm
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

            cp -r $src/. .
            chmod -R u+w .

            npm install --omit=dev --ignore-scripts

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out
            shopt -s dotglob
            cp -r ./* $out/
            shopt -u dotglob
            runHook postInstall
          '';
        };

        dexter = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = npmDeps;

          nativeBuildInputs = with pkgs; [
            gcc
            makeWrapper
            nodejs_20
            pkg-config
            python3
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            export HOME=$TMPDIR
            export npm_config_build_from_source=true
            export npm_config_nodedir=${pkgs.nodejs_20}
            export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

            chmod -R u+w .
            patchShebangs node_modules
            npm rebuild better-sqlite3 --build-from-source

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/${pname} $out/bin
            shopt -s dotglob
            cp -r ./* $out/lib/${pname}/
            shopt -u dotglob

            makeWrapper ${pkgs.bun}/bin/bun $out/bin/dexter \
              --add-flags "$out/lib/${pname}/src/index.tsx" \
              --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
              --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS "true"

            makeWrapper ${pkgs.bun}/bin/bun $out/bin/dexter-gateway \
              --add-flags "$out/lib/${pname}/src/gateway/index.ts run" \
              --set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD "1" \
              --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS "true"

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Autonomous financial research agent";
            homepage = "https://github.com/virattt/dexter";
            license = licenses.mit;
            mainProgram = "dexter";
            platforms = linuxSystems;
          };
        };
      in
      {
        packages = {
          default = dexter;
          inherit dexter;
        };

        apps.default = {
          type = "app";
          program = "${dexter}/bin/dexter";
        };
      }
    );
}
