# The default reusable flake-parts module is the local-only project module.
# Accepts the same explicit dependency-injection arguments as ./project.nix.
args: import ./project.nix args
