#!/usr/bin/env bash
set -euo pipefail

package="${1:?Usage: test-daemon.sh PACKAGE_PATH}"
package="$(cd "$package" && pwd)"
test_home="$(mktemp -d "$HOME/.codex-test.XXXXXX")"
export CODEX_HOME="$test_home"

cleanup() {
  timeout 30 "$package/bin/codex" app-server daemon stop >/dev/null 2>&1 || true
  rm -rf "$test_home"
}
trap cleanup EXIT

timeout 30 "$package/bin/codex" --version
timeout 30 "$package/codex-path/rg" --version
if [ -x "$package/codex-resources/zsh/bin/zsh" ]; then
  timeout 30 "$package/codex-resources/zsh/bin/zsh" --version
fi
timeout 180 "$package/bin/codex" app-server daemon bootstrap
timeout 30 "$package/bin/codex" app-server daemon version | jq -e '.status == "running"'
test -S "$CODEX_HOME/app-server-control/app-server-control.sock"
timeout 180 "$package/bin/codex" app-server daemon update --from-cli --yes
timeout 30 "$package/bin/codex" app-server daemon version | jq -e '.status == "running"'
test -S "$CODEX_HOME/app-server-control/app-server-control.sock"
timeout 30 "$package/bin/codex" app-server daemon stop
