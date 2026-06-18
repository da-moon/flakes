#!/usr/bin/env python3
"""Null residual /nix/store path strings left in compiled .node addons.

node-gyp links native addons against build-time store paths (this fixed-output
derivation's own $out/lib, plus gcc/glibc). patchelf removes the DT_RUNPATH tag
but cannot garbage-collect the orphaned string in .dynstr, and a fixed-output
derivation rejects any surviving /nix/store reference. These strings are dead
(no tag references them after --remove-rpath), so we overwrite each store-path
byte run with NUL in place. Size is preserved and the addon stays loadable; the
runtime library path is supplied by the launcher's LD_LIBRARY_PATH.

Usage: scrub-store-strings.py <node_modules_root> [<node_modules_root> ...]
"""

import os
import re
import sys

STORE_PATH = re.compile(rb"/nix/store/[a-z0-9]{32}-[^\x00]*")


def scrub_file(path):
    with open(path, "rb") as fh:
        data = bytearray(fh.read())
    changed = 0
    for match in STORE_PATH.finditer(bytes(data)):
        for i in range(match.start(), match.end()):
            data[i] = 0
        changed += 1
    if changed:
        with open(path, "wb") as fh:
            fh.write(data)
    return changed


def main(roots):
    total = 0
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if not name.endswith(".node"):
                    continue
                fpath = os.path.join(dirpath, name)
                if os.path.islink(fpath):
                    continue
                total += scrub_file(fpath)
    print(f"scrub-store-strings: nulled {total} store-path runs", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
