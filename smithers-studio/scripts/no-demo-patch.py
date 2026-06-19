#!/usr/bin/env python3
"""Default Studio to the real "studio" shell when VITE_SMITHERS_STUDIO_NO_DEMO=1.

The studio shell is mock-free (Runs/Home/Workspace/Workflows all read the live
workspace); the all-mock data (the acme-web project, canned chat feed, prototype
dashboards/History) lives ONLY in the upstream "chat" shell, which defaults on.
So the entire "show only real data" goal reduces to landing on the studio shell.

This is the SINGLE source patch we apply (the home-manager `hideDemoData` option
flips the flag). It is gated on the env var, so default-unset = upstream behavior
byte-for-byte. Applied at build time; the one anchor below is asserted to match
exactly once, so an upstream change fails the build loudly instead of silently
reverting to the chat shell.

Note: shellMode also persists to localStorage, so even without this patch a user
can type `/studio` once and it sticks per browser. This patch just makes the
mock-free shell the default for every fresh browser.
"""
import sys
from pathlib import Path

FLAG = 'import.meta.env.VITE_SMITHERS_STUDIO_NO_DEMO === "1"'

EDITS = [
    (
        "src/useStudioStore.ts",
        'function readShellMode(): ShellMode {\n'
        '  if (typeof localStorage === "undefined") return "chat";\n'
        '  return localStorage.getItem(SHELL_MODE_STORAGE_KEY) === "studio" ? "studio" : "chat";\n'
        '}',
        'function readShellMode(): ShellMode {\n'
        '  const noDemo = ' + FLAG + ';\n'
        '  if (typeof localStorage === "undefined") return noDemo ? "studio" : "chat";\n'
        '  const stored = localStorage.getItem(SHELL_MODE_STORAGE_KEY);\n'
        '  if (stored === "studio") return "studio";\n'
        '  if (stored === "chat") return "chat";\n'
        '  return noDemo ? "studio" : "chat";\n'
        '}',
    ),
]


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: no-demo-patch.py <appDir>")
    app = Path(sys.argv[1])
    for rel, old, new in EDITS:
        path = app / rel
        text = path.read_text()
        count = text.count(old)
        if count != 1:
            sys.exit(
                f"no-demo-patch: expected exactly 1 match for the anchor in "
                f"{rel}, found {count}. Upstream source changed; update "
                f"no-demo-patch.py."
            )
        path.write_text(text.replace(old, new))
        print(f"no-demo-patch: patched {rel}")


if __name__ == "__main__":
    main()
