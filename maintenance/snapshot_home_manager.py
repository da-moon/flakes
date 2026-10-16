#!/usr/bin/env python3
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

DA_MOON = "github.com/da-moon/flakes"


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


def blocks(text):
    starts = list(re.finditer(r"(?m)^\s*dmTools\s*=\s*\{", text))
    found = []
    for match in starts:
        level = 0
        for index in range(match.end() - 1, len(text)):
            if text[index] == "{": level += 1
            elif text[index] == "}":
                level -= 1
                if level == 0:
                    end = index + 1 + (index + 1 < len(text) and text[index + 1] == ";")
                    found.append((match.start(), end))
                    break
        else:
            raise ValueError("unbalanced dmTools block")
    return found


def normalized_dmtools(text):
    out, offset = [], 0
    for start, end in blocks(text):
        out.append(text[offset:start])
        block = text[start:end]
        out.append(re.sub(r'(\bversion\s*=\s*)"[^"]*"', r'\1"<normalized>"', block))
        offset = end
    out.append(text[offset:])
    return "".join(out)


def hashes(root, pattern, normalize=False):
    result = {}
    for path in sorted(root.glob(pattern)):
        if path.is_file():
            result[str(path.relative_to(root))] = (
                sha256(normalized_dmtools(path.read_text())) if normalize
                else hashlib.sha256(path.read_bytes()).hexdigest()
            )
    return result


def tool_nodes(lock):
    nodes = lock["nodes"]
    return {
        name for name, node in nodes.items()
        if isinstance(node.get("original", {}).get("url"), str)
        and DA_MOON in node["original"]["url"]
    }


def snapshot(root):
    lock = json.loads((root / "flake.lock").read_text())
    tools = tool_nodes(lock)
    root_inputs = lock["nodes"][lock.get("root", "root")]["inputs"]
    return {
        "top_level_nix_without_dmtools_versions": hashes(root, "*.nix", True),
        "darwin_files": hashes(root, "darwin/**/*"),
        "non_tool_root_inputs": {
            name: lock["nodes"][node].get("locked") if isinstance(node, str) else node
            for name, node in root_inputs.items()
            if not isinstance(node, str) or node not in tools
        },
    }


def dmtool_entries(text):
    result = []
    for start, end in blocks(text):
        block = text[start:end]
        for match in re.finditer(r'(?ms)^\s{8}([A-Za-z0-9-]+)\s*=\s*\{(.*?)^\s{8}\};', block):
            name, body = match.groups()
            version = re.search(r'\bversion\s*=\s*"([^"]+)"', body)
            override = re.search(r'\binput\s*=\s*"([^"]+)"', body)
            if version:
                result.append((name, override.group(1) if override else name, version.group(1)))
    return result


def verify_pins(root, repo):
    entries = [entry for path in root.glob("*.nix") for entry in dmtool_entries(path.read_text())]
    if not entries:
        raise ValueError("no explicit non-Darwin dmTools pins found")
    for name, source, version in entries:
        releases = json.loads((repo / source / "releases.json").read_text())
        if version != releases.get("latest"):
            raise ValueError(f"pin {name} is not latest")
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    lock = json.loads((root / "flake.lock").read_text())
    tools = tool_nodes(lock)
    if not tools:
        raise ValueError("no flakes tool inputs found")
    wrong = [name for name in tools if lock["nodes"][name].get("locked", {}).get("rev") != head]
    if wrong:
        raise ValueError("tool inputs are not locked at the pushed flakes revision")



def verify_audit(inventory_path, audit_path, result_path):
    inventory = inventory_path.read_text().splitlines()
    expected = set(inventory)
    seen = {}
    for line_number, line in enumerate(audit_path.read_text().splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError(f"malformed updater audit line {line_number}")
        script, attempt_text, rc_text = fields
        if script not in expected:
            raise ValueError(f"unknown updater in audit: {script}")
        if not attempt_text.isdigit() or int(attempt_text) < 1:
            raise ValueError(f"invalid attempt in audit line {line_number}")
        try:
            rc = int(rc_text)
        except ValueError as error:
            raise ValueError(f"invalid exit code in audit line {line_number}") from error
        records = seen.setdefault(script, [])
        if int(attempt_text) != len(records) + 1:
            raise ValueError(f"non-contiguous attempts for {script}")
        records.append(rc)
    if set(seen) != expected:
        raise ValueError("updater audit omits a discovered script")
    if any(records[-1] != 0 for records in seen.values()):
        raise ValueError("an updater audit ends in failure")
    result = json.loads(result_path.read_text())
    reported = result.get("updater_results", [])
    by_script = {}
    for entry in reported:
        script = entry.get("script")
        if script in by_script:
            raise ValueError(f"duplicate updater result: {script}")
        by_script[script] = entry
    if set(by_script) != expected:
        raise ValueError("updater result inventory differs from discovered inventory")
    for script, records in seen.items():
        entry = by_script[script]
        if entry.get("attempts") != len(records) or entry.get("final_exit_code") != records[-1]:
            raise ValueError(f"updater result does not match audit: {script}")

def main():
    if len(sys.argv) == 5 and sys.argv[1] == "verify-audit":
        verify_audit(*(Path(value) for value in sys.argv[2:]))
        return
    if len(sys.argv) < 4:
        raise SystemExit("usage: snapshot_home_manager.py OPERATION ROOT ARG")
    operation, root_arg = sys.argv[1:3]
    root = Path(root_arg)
    if operation == "snapshot" and len(sys.argv) == 4:
        Path(sys.argv[3]).write_text(json.dumps(snapshot(root), sort_keys=True, separators=(",", ":")) + "\n")
    elif operation == "verify" and len(sys.argv) == 4:
        previous = json.loads(Path(sys.argv[3]).read_text())
        if snapshot(root) != previous:
            raise SystemExit("Home Manager changed outside dmTools versions, Darwin, or non-tool locked data")
    elif operation == "verify-pins" and len(sys.argv) == 4:
        verify_pins(root, Path(sys.argv[3]))
    else:
        raise SystemExit("invalid snapshot_home_manager.py arguments")


if __name__ == "__main__":
    main()
