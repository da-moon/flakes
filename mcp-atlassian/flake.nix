{
  description = "MCP server for Atlassian products (Jira & Confluence)";

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
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        # fastmcp -> py-key-value-aio carries test-only KV-store backends
        # (duckdb -> arrow-cpp, ...) in its check inputs; arrow-cpp is marked
        # broken on x86_64-darwin, which would refuse evaluation on Intel macs
        # even though the runtime closure never imports those backends. Strip
        # py-key-value-aio's check inputs via a scope override so fastmcp
        # (and this package) build on all four systems.
        py = pkgs.python3Packages.overrideScope (final: prev: {
          py-key-value-aio = prev.py-key-value-aio.overridePythonAttrs (_: {
            doCheck = false;
            nativeCheckInputs = [ ];
          });
        });
        pname = "mcp-atlassian";

        # markdown-to-confluence is not packaged in nixpkgs. Build it from the
        # PyPI sdist. Its declared lower bounds (cattrs>=26.1, lxml>=6.1,
        # pymdown-extensions>=11.0, pathspec>=1.1, requests>=2.34, markdown>=3.10)
        # run ahead of nixpkgs-26.05; relax them to the packaged versions.
        markdownToConfluence = py.buildPythonPackage rec {
          pname = "markdown-to-confluence";
          version = "0.6.2";
          pyproject = true;

          # nixpkgs fetchPypi builds a legacy `source/.../<name>.tar.gz` URL that
          # 404s (PyPI serves the sdist at a content-hash path with an underscore
          # filename), so fetch the exact sdist URL directly.
          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/0a/7a/7dba168786853d1db11a1de361fabf673a0c03de6129dce33e720e988663/markdown_to_confluence-0.6.2.tar.gz";
            hash = "sha256-FfROlA1fKJTD5Sr85R/BL46dPJujQe2XGvG9neNj2Mg=";
          };

          nativeBuildInputs = [ py.setuptools ];

          propagatedBuildInputs = [
            py.cattrs
            py.lxml
            py.markdown
            py.orjson
            py.pymdown-extensions
            py.pyyaml
            py.pathspec
            py.requests
            py.truststore
          ];

          pythonRelaxDeps = [
            "cattrs"
            "lxml"
            "markdown"
            "pymdown-extensions"
            "pathspec"
            "requests"
          ];

          doCheck = false;
        };

        # Builder: derive an mcp-atlassian package from one releases.json entry.
        # Only version and the source hash come from the version table; the
        # package logic is shared across all retained releases.
        mk =
          _key: entry:
          let
            version = entry.version;
          in
          py.buildPythonApplication {
            inherit pname version;
            pyproject = true;

            meta = with lib; {
              description = "MCP server bridging Atlassian Jira & Confluence with AI models";
              homepage = "https://github.com/sooperset/mcp-atlassian";
              license = licenses.mit;
              mainProgram = "mcp-atlassian";
              platforms = systems;
              maintainers = [ ];
            };

            # fetchPypi's guessed `source/.../<name>.tar.gz` URL 404s (PyPI serves
            # the sdist at a content-hash path with an underscore filename), so the
            # exact sdist URL is stored per-entry in releases.json and fetched
            # directly. scripts/update-version.sh resolves it from the PyPI JSON.
            src = pkgs.fetchurl {
              url = entry.url;
              hash = entry.hash;
            };

            # Upstream derives the version dynamically from git tags via
            # uv-dynamic-versioning (fallback "0.0.0"). An unpacked sdist has
            # no .git, so bake the version statically. Also drop the two
            # type-checking-only stubs: types-cachetools is absent from
            # nixpkgs and neither stub has any runtime effect.
            postPatch = ''
              substituteInPlace pyproject.toml \
                --replace-fail 'dynamic = ["version"]' 'version = "${version}"'
              sed -i -e '/types-cachetools/d' -e '/types-python-dateutil/d' pyproject.toml
            '';

            # build-system.requires declares hatchling + uv-dynamic-versioning;
            # the version is baked statically via postPatch, but the build backend
            # still imports uv-dynamic-versioning, so it must be present.
            nativeBuildInputs = [
              py.hatchling
              py."uv-dynamic-versioning"
            ];

            # Several 0.23.0 bounds run ahead of nixpkgs-26.05 and are relaxed
            # to the packaged versions (same approach as cloudcraft-mcp):
            #   mcp>=1.27.0,<2.0.0  -> nixpkgs 1.26.0  (one minor behind)
            #   fastmcp>=3.2.4,<4.0 -> nixpkgs 3.2.3  (one patch behind)
            #   fakeredis<2.35.0    -> nixpkgs 2.36.2 (above the upper bound)
            # The build, the `mcp_atlassian` import (pythonImportsCheck), and
            # `mcp-atlassian --help` all pass with the relaxed versions; a live
            # Atlassian round-trip is not exercised here. fastmcp is the layer
            # mcp-atlassian talks to, and nixpkgs' fastmcp 3.2.3 was itself
            # built against mcp 1.26, so the pair is internally consistent.
            # Revisit once nixpkgs ships mcp >=1.27 / fastmcp >=3.2.4.
            pythonRelaxDeps = [
              "mcp"
              "fastmcp"
              "fakeredis"
              "markdown-to-confluence"
            ];

            propagatedBuildInputs = [
              markdownToConfluence
              py.anyio
              py.atlassian-python-api
              py.beautifulsoup4
              py.cachetools
              py.click
              py.fakeredis
              py.fastmcp
              py.httpx
              py.keyring
              py.markdown
              py.markdownify
              py.mcp
              py.pydantic
              py.pysocks
              py.python-dateutil
              py.python-dotenv
              py.requests
              py.starlette
              py.thefuzz
              py.trio
              py.truststore
              py.unidecode
              py.urllib3
              py.uvicorn
            ];

            doCheck = false;
            pythonImportsCheck = [ "mcp_atlassian" ];
          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `mcp-atlassian_<sanitized-key>` package per table entry.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "${pname}_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
        # Self-guarding wrapper for MCP clients. mcp-atlassian silently
        # exit-loops when started with no Atlassian product configured (no env,
        # no args), which a global stdio registration would crash-loop on every
        # session. This wrapper fails fast with a clear message if NEITHER
        # JIRA_URL nor CONFLUENCE_URL is set (Cloud: also *_USERNAME +
        # *_API_TOKEN; Server/DC: *_PERSONAL_TOKEN), then execs the real server
        # with all args/env passed through unchanged.
        mcpAtlassianAuto = pkgs.writeShellScriptBin "mcp-atlassian-auto" ''
          if [ -z "''${JIRA_URL:-}" ] && [ -z "''${CONFLUENCE_URL:-}" ]; then
            echo "mcp-atlassian-auto: no Atlassian product configured." >&2
            echo "  Set JIRA_URL and/or CONFLUENCE_URL (plus credentials):" >&2
            echo "    Cloud:        *_USERNAME + *_API_TOKEN" >&2
            echo "    Server/DC:    *_PERSONAL_TOKEN" >&2
            echo "  via your MCP client's env block, then re-run." >&2
            exit 1
          fi
          exec ${latestPkg}/bin/mcp-atlassian "$@"
        '';
      in
      {
        packages = {
          default = latestPkg;
          "mcp-atlassian" = latestPkg;
          "mcp-atlassian-auto" = mcpAtlassianAuto;
        } // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/mcp-atlassian";
          };
          "mcp-atlassian" = {
            type = "app";
            program = "${latestPkg}/bin/mcp-atlassian";
          };
          "mcp-atlassian-auto" = {
            type = "app";
            program = "${mcpAtlassianAuto}/bin/mcp-atlassian-auto";
          };
        };
      }
    );
}
