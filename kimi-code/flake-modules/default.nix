# Reusable flake-parts module for project-level Kimi Code configuration.
{ mkProjectIntegration, kimiPackage }:
import ./project.nix { inherit mkProjectIntegration kimiPackage; }
