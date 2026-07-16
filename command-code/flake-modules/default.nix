# Reusable flake-parts module for project-level Command Code configuration.
{ mkProjectIntegration, commandCodePackage }:
import ./project.nix { inherit mkProjectIntegration commandCodePackage; }
