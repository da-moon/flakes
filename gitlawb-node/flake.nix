{
  description = "Gitlawb Node - decentralized git node: daemon, gl CLI, and git-remote-gitlawb helper";

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

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Map a nix system to the upstream release-asset target triple.
        # Linux assets are static musl builds and Darwin assets are signed
        # binaries, so no autoPatchelf is needed on any platform.
        targetBySystem = {
          "aarch64-linux" = "aarch64-unknown-linux-musl";
          "x86_64-linux" = "x86_64-unknown-linux-musl";
          "aarch64-darwin" = "aarch64-apple-darwin";
          "x86_64-darwin" = "x86_64-apple-darwin";
        };

        target = targetBySystem.${system} or (throw "Unsupported system for gitlawb-node flake: ${system}");

        # Builder: derive a gitlawb-node package from one releases.json entry.
        mk =
          key: entry:
          let
            version = entry.version;
            binarySha256 =
              entry.hashes.${system} or (throw "Missing hash for system ${system} in gitlawb-node release ${key}");
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "gitlawb-node";
            inherit version;

            meta = with lib; {
              description = "Decentralized git node — self-hostable, Ed25519 identity, HTTP signatures, libp2p gossip";
              longDescription = ''
                Gitlawb Node is the open-source node software behind the Gitlawb
                network: a self-hostable decentralized git node with Ed25519
                identities (did:key), RFC 9421 HTTP signatures, git smart-HTTP,
                Postgres metadata, and libp2p gossip. The release ships three
                binaries: gitlawb-node (the daemon), gl (the CLI), and
                git-remote-gitlawb (the gitlawb:// remote helper).
              '';
              homepage = "https://github.com/Gitlawb/node";
              license = with licenses; [
                mit
                asl20
              ];
              mainProgram = "gitlawb-node";
              platforms = systems;
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/Gitlawb/node/releases/download/v${version}/gitlawb-node-${version}-${target}.tar.gz";
              hash = binarySha256;
            };

            # No build needed - precompiled static binaries
            dontBuild = true;
            dontConfigure = true;
            dontStrip = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D gitlawb-node $out/bin/gitlawb-node
              install -m755 -D gl $out/bin/gl
              install -m755 -D git-remote-gitlawb $out/bin/git-remote-gitlawb
              runHook postInstall
            '';

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `gitlawb-node_<sanitized-key>` package per entry in the table.
        versionPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "gitlawb-node_${sanitizeKey key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );
      in
      {
        packages = {
          default = latestPkg;
          gitlawb-node = latestPkg;
        }
        // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/gitlawb-node";
          };
          gitlawb-node = {
            type = "app";
            program = "${latestPkg}/bin/gitlawb-node";
          };
          gl = {
            type = "app";
            program = "${latestPkg}/bin/gl";
          };
          git-remote-gitlawb = {
            type = "app";
            program = "${latestPkg}/bin/git-remote-gitlawb";
          };
        };
      }
    );
}
