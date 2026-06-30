{
  description = "FFF MCP Server - fast, typo-resistant file search for AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        version = "0.9.6";

        # Architecture-specific configuration. fff-mcp ships prebuilt,
        # statically-linked (musl on Linux) per-target binaries as raw release
        # assets named fff-mcp-<rust-target>.
        archConfig = {
          "aarch64-linux" = {
            target = "aarch64-unknown-linux-musl";
            sha256 = "sha256-qYEMkFavptnorB56Px8V+Oy/3BalkunSbkskNO+XpnU=";
          };
          "x86_64-linux" = {
            target = "x86_64-unknown-linux-musl";
            sha256 = "sha256-ECzq8XPvd2vsszIiFun2tcrvmXxADF0V8RLOTeQKH1o=";
          };
          "aarch64-darwin" = {
            target = "aarch64-apple-darwin";
            sha256 = "sha256-Kaf63q+wYvPllUsauMaeFNyiT14GHNjTseobqzhaN1Q=";
          };
          "x86_64-darwin" = {
            target = "x86_64-apple-darwin";
            sha256 = "sha256-WCWTJMLBOhtvJPExOMLNPq6f8g4FIBpTm+uPIESmUao=";
          };
        };

        # Get config for current system, fallback to x86_64-linux if unknown
        currentArch = archConfig.${system} or archConfig."x86_64-linux";

        fff-mcp = pkgs.stdenv.mkDerivation rec {
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
            url = "https://github.com/dmtrKovalenko/fff.nvim/releases/download/v${version}/fff-mcp-${currentArch.target}";
            sha256 = currentArch.sha256;
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

      in
      {
        packages = {
          default = fff-mcp;
          fff-mcp = fff-mcp;
        };

        apps = {
          default = {
            type = "app";
            program = "${fff-mcp}/bin/fff-mcp";
          };
          fff-mcp = {
            type = "app";
            program = "${fff-mcp}/bin/fff-mcp";
          };
        };
      }
    );
}
