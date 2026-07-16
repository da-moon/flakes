{
  description = "UniClipboard CLI - cross-platform peer-to-peer clipboard synchronization";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        targetBySystem = {
          "x86_64-linux" = "x86_64-unknown-linux-musl";
          "aarch64-linux" = "aarch64-unknown-linux-musl";
          "x86_64-darwin" = "x86_64-apple-darwin";
          "aarch64-darwin" = "aarch64-apple-darwin";
        };

        mk =
          key: entry:
          let
            version = entry.version;
            target = targetBySystem.${system};
          in
          pkgs.stdenvNoCC.mkDerivation {
            pname = "uniclipboard-cli";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://github.com/UniClipboard/UniClipboard/releases/download/v${version}/uniclipboard-cli-${version}-${target}.tar.gz";
              hash = entry.hashes.${system};
            };

            sourceRoot = ".";
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;
            dontPatchELF = true;

            installPhase = ''
              runHook preInstall

              # The CLI launches a matching sibling daemon. Keep both release
              # binaries together; mixing versions is unsupported upstream.
              install -m755 -D uniclip "$out/bin/uniclip"
              install -m755 -D uniclipd "$out/bin/uniclipd"

              runHook postInstall
            '';

            meta = with lib; {
              description = "Headless CLI for UniClipboard's encrypted peer-to-peer clipboard sync";
              homepage = "https://github.com/UniClipboard/UniClipboard";
              license = licenses.agpl3Only;
              sourceProvenance = [ sourceTypes.binaryNativeCode ];
              mainProgram = "uniclip";
              platforms = systems;
              maintainers = [ ];
            };
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "uniclipboard-cli_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          uniclipboard-cli = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/uniclip";
          };
          uniclip = {
            type = "app";
            program = "${latestPkg}/bin/uniclip";
          };
          uniclipd = {
            type = "app";
            program = "${latestPkg}/bin/uniclipd";
          };
        };
      }
    );
}
