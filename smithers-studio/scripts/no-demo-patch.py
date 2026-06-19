#!/usr/bin/env python3
"""Gate Studio's demo/mock seed data behind VITE_SMITHERS_STUDIO_NO_DEMO.

Applied at build time so the package always carries the gating code. The flag
defaults unset, so upstream behavior is preserved byte-for-byte; set
VITE_SMITHERS_STUDIO_NO_DEMO=1 (the home-manager `hideDemoData` option) to show
only the real connected workspace. studio runs `vite dev`, whose default env
prefix is VITE_, so the var reaches import.meta.env at dev-server start.

Each replacement is asserted to match exactly once, so an upstream source change
fails the build loudly instead of silently leaving the mock data in place.
"""
import sys
from pathlib import Path

FLAG = 'import.meta.env.VITE_SMITHERS_STUDIO_NO_DEMO === "1"'

EDITS = [
    # Default to the real studio shell (not the all-mock chat shell) when the
    # flag is set and the user has no explicit stored preference.
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
    # Seed one real "workspace" project instead of the mock acme-web list.
    (
        "src/chat/projects/projectStore.ts",
        'export const useProjectStore = create<ProjectState>((set) => ({\n'
        '  projects: mockProjects,\n'
        '  currentProjectId: mockProjects[0].id,',
        'const seedProjects: Project[] =\n'
        '  ' + FLAG + '\n'
        '    ? [{ id: "workspace", name: "workspace", color: "#4C8DFF" }]\n'
        '    : mockProjects;\n'
        'export const useProjectStore = create<ProjectState>((set) => ({\n'
        '  projects: seedProjects,\n'
        '  currentProjectId: seedProjects[0].id,',
    ),
    # Start the chat feed empty instead of from canned mock messages.
    (
        "src/chat/feed/useChatFeed.ts",
        '  const [all, setAll] = useState<ChatItem[]>(mockChatFeed);',
        '  const [all, setAll] = useState<ChatItem[]>(' + FLAG + ' ? [] : mockChatFeed);',
    ),
    # Start with no seeded demo toasts.
    (
        "src/chat/toasts/toastStore.ts",
        '  toasts: mockToasts,',
        '  toasts: ' + FLAG + ' ? [] : mockToasts,',
    ),
    # Open the REAL Runs/Memory/etc. surfaces from the Views menu instead of the
    # prototype mock dashboards.
    (
        "src/chat/overlay/dashboard/dashboardForView.ts",
        'export function dashboardForView(view: ViewId): DashboardKey | null {\n'
        '  switch (view) {',
        'export function dashboardForView(view: ViewId): DashboardKey | null {\n'
        '  if (' + FLAG + ') return null;\n'
        '  switch (view) {',
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
