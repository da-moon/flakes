{
  description = "FFF MCP Server - fast, typo-resistant file search for AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitize = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Map nix system -> fff-mcp release-asset rust target triple. fff-mcp
        # ships prebuilt, statically-linked (musl on Linux) per-target binaries
        # as raw release assets named fff-mcp-<rust-target>.
        targetBySystem = {
          "aarch64-linux" = "aarch64-unknown-linux-musl";
          "x86_64-linux" = "x86_64-unknown-linux-musl";
          "aarch64-darwin" = "aarch64-apple-darwin";
          "x86_64-darwin" = "x86_64-apple-darwin";
        };

        # Builder: derive a fff-mcp package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/src-url/hash
        # now come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            target = targetBySystem.${system};
            sha256 = entry.hashes.${system};
          in
          pkgs.stdenv.mkDerivation rec {
            pname = "fff-mcp";
            inherit version;

            meta = with pkgs.lib; {
              description = "FFF MCP server - fast, typo-resistant file search for AI agents";
              longDescription = ''
                fff-mcp exposes FFF - a frecency-ranked, typo-resistant file and
                content search engine - as a Model Context Protocol (MCP) server.
                It provides ffgrep, fffind, and fff-multi-grep tools so AI coding
                agents (Claude Code, Codex, OpenCode, Cursor, ...) can search a
                repository with fewer roundtrips and less wasted context than the
                built-in grep/find tools.
              '';
              homepage = "https://github.com/dmtrKovalenko/fff";
              license = licenses.mit;
              platforms = [
                "aarch64-linux"
                "x86_64-linux"
                "aarch64-darwin"
                "x86_64-darwin"
              ];
              mainProgram = "fff-mcp";
              maintainers = [ ];
            };

            src = pkgs.fetchurl {
              url = "https://github.com/dmtrKovalenko/fff.nvim/releases/download/v${version}/fff-mcp-${target}";
              inherit sha256;
            };

            # Raw single-file binary asset - there is nothing to unpack.
            dontUnpack = true;
            dontBuild = true;
            dontConfigure = true;

            # Statically linked (musl on Linux) - don't strip or patch the ELF
            # interpreter; doing so would corrupt the static binary.
            dontStrip = true;
            dontPatchELF = true;

            installPhase = ''
              runHook preInstall
              install -m755 -D "$src" "$out/bin/fff-mcp"
              runHook postInstall
            '';
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `fff-mcp_<sanitized-key>` package per entry in the table.
        versionedPackages = builtins.listToAttrs (
          builtins.map (key: {
            name = "fff-mcp_${sanitize key}";
            value = mk key releases.versions.${key};
          }) (builtins.attrNames releases.versions)
        );

      in
      {
        packages = versionedPackages // {
          default = latestPkg;
          fff-mcp = latestPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/fff-mcp";
          };
          fff-mcp = {
            type = "app";
            program = "${latestPkg}/bin/fff-mcp";
          };
        };
      }
    );
}
