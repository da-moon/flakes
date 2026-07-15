# The default reusable flake-parts module is the project integration module.
# Accepts the same dependency-injection arguments as ./project.nix.
args: import ./project.nix args
