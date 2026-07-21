# Reusable flake-parts module factory for project-scoped memlawb integration.
#
# A consuming project flake does:
#
#   imports = [ inputs.memlawb.flakeModules.default ];
#   memlawb.project = {
#     enable = true;
#     url = "https://memory.example.com";  # or null for http://localhost:8080
#     namespace = "project:myrepo";
#   };
#
# That gives the project:
#   - a `memlawb` dev shell with the CLI on PATH (client env baked in,
#     `memlawb mcp` ready to register with any MCP client),
#   - `apps.memlawb` / `apps.memlawb-mcp`,
#   - a managed `memlawb` entry in the project's `.mcp.json` (sync app
#     `memlawb-mcp-sync` + `memlawb-mcp-drift` check).
#
# Package selection is intentionally per-system:
#
#   perSystem = { pkgs, ... }: {
#     memlawb.project.package = ...;
#     memlawb.project.extraPackages = [ pkgs.nodejs ];
#   };
{
  memlawbPackage ? null,
}:
{
  config,
  lib,
  self,
  flake-parts-lib,
  ...
}:
let
  cfg = config.memlawb.project;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  packageFor =
    pkgs:
    if memlawbPackage == null then
      null
    else if builtins.isFunction memlawbPackage then
      memlawbPackage pkgs
    else
      memlawbPackage;

  # Mirror of serena's validateProjectRoot: only root flakes or normalized
  # relative paths like "packages/api" are supported.
  validProjectRoot =
    root:
    root == "."
    || (
      !(lib.hasPrefix "/" root)
      && builtins.match ".*(^|/)\\.\\.(/|$).*" root == null
      && builtins.match ".*\n.*" root == null
    );
  projectRoot =
    if validProjectRoot cfg.projectRoot then
      cfg.projectRoot
    else
      throw "memlawb.project.projectRoot must be \".\" or a normalized relative path (got ${builtins.toJSON cfg.projectRoot})";
in
{
  options.memlawb.project = {
    enable = mkEnableOption "memlawb project integration (CLI dev shell + .mcp.json MCP registration)";

    projectRoot = mkOption {
      type = types.str;
      default = ".";
      example = "packages/api";
      description = ''
        Directory (relative to the consuming flake's Git root) whose
        .mcp.json the memlawb MCP entry is synced into.
      '';
    };

    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://memory.example.com";
      description = ''
        Base URL of the memlawb server (MEMLAWB_URL). `null` keeps the
        upstream default http://localhost:8080.
      '';
    };

    namespace = mkOption {
      type = types.str;
      default = "user:me";
      example = "project:myrepo";
      description = "Default namespace for CLI and MCP calls (MEMLAWB_NAMESPACE).";
    };

    scan = mkOption {
      type = types.enum [
        "block"
        "warn"
        "off"
      ];
      default = "block";
      description = "Secret-scan policy applied before encryption (MEMLAWB_SCAN).";
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/home/alice/.secrets/memlawb";
      description = ''
        File sourced by the dev shell and by the wrapped CLI at runtime;
        define MEMLAWB_PASSPHRASE (and MEMLAWB_API_KEY when the server
        requires auth) there to keep secrets out of the Nix store.
      '';
    };

    mcp = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Manage a memlawb entry in the project's .mcp.json via the
          memlawb-mcp-sync app and the memlawb-mcp-drift check.
        '';
      };

      name = mkOption {
        type = types.str;
        default = "memlawb";
        description = "Key of the memlawb entry under .mcp.json's mcpServers.";
      };
    };
  };

  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { pkgs, ... }:
    {
      options.memlawb.project = {
        package = mkOption {
          type = types.nullOr types.package;
          default = packageFor pkgs;
          defaultText = lib.literalExpression "the memlawb flake's package for this system";
          description = ''
            memlawb package exposed in the project shell and MCP entry. A
            null value is allowed for module composition, but evaluation of
            enabled memlawb outputs requires a package.
          '';
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          example = lib.literalExpression "[ pkgs.bun pkgs.nodejs ]";
          description = "Additional packages exposed in the memlawb development shell.";
        };

        devShellName = mkOption {
          type = types.str;
          default = "memlawb";
          description = "Name of the devShell carrying the memlawb integration.";
        };
      };
    }
  );

  config = mkIf cfg.enable {
    perSystem =
      { config, pkgs, ... }:
      let
        pcfg = config.memlawb.project;
        package =
          if pcfg.package != null then
            pcfg.package
          else
            throw "memlawb.project: no memlawb package available for this system";

        wrapped = import ../lib/wrap-client.nix {
          inherit pkgs package;
          client = {
            inherit (cfg)
              url
              namespace
              scan
              environmentFile
              ;
            apiKey = null;
            passphrase = null;
          };
        };

        mcpApp = pkgs.writeShellScriptBin "memlawb-mcp" ''
          exec ${wrapped}/bin/memlawb mcp "$@"
        '';

        mcpJson = pkgs.writeText "memlawb-mcp.json" (
          builtins.toJSON {
            mcpServers.${cfg.mcp.name} = {
              command = "${wrapped}/bin/memlawb";
              args = [ "mcp" ];
              env = {
                MEMLAWB_NAMESPACE = cfg.namespace;
                MEMLAWB_SCAN = cfg.scan;
              }
              // lib.optionalAttrs (cfg.url != null) {
                MEMLAWB_URL = cfg.url;
              };
            };
          }
        );

        syncApp = pkgs.writeShellApplication {
          name = "memlawb-mcp-sync";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.git
            pkgs.jq
          ];
          text = ''
            rendered=${mcpJson}
            name=${lib.escapeShellArg cfg.mcp.name}
            target="$(git rev-parse --show-toplevel)/${projectRoot}/.mcp.json"
            entry="$(jq -c --arg n "$name" '.mcpServers[$n]' "$rendered")"

            if [ -L "$target" ]; then
              echo "memlawb-mcp-sync: refusing to write through symlink $target" >&2
              exit 1
            fi

            if [ -f "$target" ]; then
              if ! jq -e 'type == "object"' "$target" >/dev/null; then
                echo "memlawb-mcp-sync: $target is not a JSON object; refusing to modify it" >&2
                exit 1
              fi
              current="$(jq -c --arg n "$name" '.mcpServers[$n] // empty' "$target")"
              if [ "$current" = "$entry" ]; then
                echo "memlawb-mcp-sync: $target already up to date"
                exit 0
              fi
              tmp="$(mktemp)"
              jq --arg n "$name" --argjson e "$entry" '.mcpServers[$n] = $e' "$target" >"$tmp"
              chmod 0644 "$tmp"
              mv -f "$tmp" "$target"
            else
              install -m 0644 "$rendered" "$target"
            fi
            echo "memlawb-mcp-sync: wrote $target — remember to git add it"
          '';
        };

        driftCheck =
          pkgs.runCommand "memlawb-mcp-drift"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
            }
            ''
              target="${self.outPath}/${projectRoot}/.mcp.json"
              name=${lib.escapeShellArg cfg.mcp.name}
              if [ ! -f "$target" ]; then
                echo "memlawb: no .mcp.json in the project — run 'nix run .#memlawb-mcp-sync' and commit it" >&2
                exit 1
              fi
              expected="$(jq -c --arg n "$name" '.mcpServers[$n]' ${mcpJson})"
              actual="$(jq -c --arg n "$name" '.mcpServers[$n] // empty' "$target")"
              if [ "$actual" != "$expected" ]; then
                echo "memlawb: .mcp.json entry '$name' drifted — run 'nix run .#memlawb-mcp-sync'" >&2
                exit 1
              fi
              touch $out
            '';
      in
      {
        packages = {
          memlawb = wrapped;
        }
        // lib.optionalAttrs cfg.mcp.enable {
          memlawb-mcp-json = mcpJson;
        };

        apps = {
          memlawb = {
            type = "app";
            program = "${wrapped}/bin/memlawb";
          };

          memlawb-mcp = {
            type = "app";
            program = "${mcpApp}/bin/memlawb-mcp";
          };
        }
        // lib.optionalAttrs cfg.mcp.enable {
          memlawb-mcp-sync = {
            type = "app";
            program = "${syncApp}/bin/memlawb-mcp-sync";
          };
        };

        devShells.${pcfg.devShellName} = pkgs.mkShell {
          packages = [ wrapped ] ++ pcfg.extraPackages;
          shellHook =
            lib.optionalString (cfg.environmentFile != null) ''
              if [ -f ${lib.escapeShellArg cfg.environmentFile} ]; then
                set -a
                . ${lib.escapeShellArg cfg.environmentFile}
                set +a
              fi
            ''
            + ''
              echo "memlawb: CLI on PATH; start the MCP server with 'memlawb mcp' (namespace ${cfg.namespace})"
            '';
        };

        checks = lib.optionalAttrs cfg.mcp.enable {
          memlawb-mcp-drift = driftCheck;
        };
      };
  };
}
