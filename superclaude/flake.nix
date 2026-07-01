{
  description = "SuperClaude CLI packaged from the PyPI wheel";

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
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Version table: consumers select the latest OR any past version.
      # New entries are appended by scripts/update-version.sh via jq — do
      # NOT hand-edit the version data in this file.
      releases = builtins.fromJSON (builtins.readFile ./releases.json);

      # Sanitize a JSON key into a valid attribute-name suffix.
      sanitizeKey = builtins.replaceStrings [ "." "-" "+" ] [ "_" "_" "_" ];
    in
    flake-utils.lib.eachSystem linuxSystems (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        py = pkgs.python3Packages;
        pname = "superclaude";

        # Builder: derive a superclaude package from one releases.json entry.
        # PRESERVES the original build logic exactly; only version/url/hash now
        # come from `entry` instead of let-bindings.
        mk =
          key: entry:
          let
            version = entry.version;
            superclaudeWheelUrl = entry.url;
            superclaudeWheelHash = entry.hash;
          in
          py.buildPythonApplication {
            inherit pname version;

            meta = with lib; {
              description = "AI-enhanced development framework for Claude Code";
              homepage = "https://github.com/SuperClaude-Org/SuperClaude_Framework";
              license = licenses.mit;
              mainProgram = "superclaude";
              platforms = linuxSystems;
              maintainers = [ ];
            };

            format = "wheel";

            src = pkgs.fetchurl {
              url = superclaudeWheelUrl;
              hash = superclaudeWheelHash;
            };

            propagatedBuildInputs = [
              py.click
              py.pytest
              py.rich
            ];

            doCheck = false;
            pythonImportsCheck = [ "superclaude" ];

          };

        latestPkg = mk releases.latest releases.versions.${releases.latest};

        # One `superclaude_<sanitized-key>` package per entry in the table.
        versionPackages = lib.mapAttrs' (
          key: entry: lib.nameValuePair "superclaude_${sanitizeKey key}" (mk key entry)
        ) releases.versions;
      in
      {
        packages = {
          default = latestPkg;
          superclaude = latestPkg;
        } // versionPackages;

        apps = {
          default = {
            type = "app";
            program = "${latestPkg}/bin/superclaude";
          };
          superclaude = {
            type = "app";
            program = "${latestPkg}/bin/superclaude";
          };
        };
      }
    );
}
