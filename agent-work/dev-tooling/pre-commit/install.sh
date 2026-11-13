#!/usr/bin/env bash
# Wire pre-commit hooks into the three repos this workspace touches.
#
# - gramps-testbed: standard layout (.pre-commit-config.yaml at root),
#   installed in-place.
# - eduralph/gramps:        hook reads ../gramps-testbed/agent-work/dev-tooling/pre-commit/gramps.yaml
# - eduralph/addons-source: hook reads ../gramps-testbed/agent-work/dev-tooling/pre-commit/addons-source.yaml
#
# Keeping the gramps + addons-source configs out-of-tree avoids
# committing dev-tooling onto fork maintenance branches that get used as
# the base for upstream PRs.
#
# **Fork-side coordination (post-consolidation).** The forks' existing
# pre-commit hooks point at the OLD path
# `../gramps-testbed/dev-tooling/pre-commit/{gramps,addons-source}.yaml`.
# After the testbed-side rename to `agent-work/dev-tooling/`, those
# hooks are broken until install.sh is re-run from this script's new
# location. The maintainer of each fork must re-run
# `agent-work/dev-tooling/pre-commit/install.sh` to refresh the hook
# against the new path. No fork-side config file moves; only the hook
# reference does.
#
# Re-running is safe: pre-commit install overwrites the hook file.
# Pass --uninstall to remove hooks from all three.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# After the agent-work/ consolidation this script lives at
# agent-work/dev-tooling/pre-commit/install.sh, so the testbed root
# is three levels up.
TESTBED_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "$TESTBED_ROOT/.." && pwd)"

GRAMPS_REPO="$WORKSPACE_ROOT/gramps"
ADDONS_REPO="$WORKSPACE_ROOT/addons-source"
GRAMPS_CONFIG="$SCRIPT_DIR/gramps.yaml"
ADDONS_CONFIG="$SCRIPT_DIR/addons-source.yaml"

mode="install"
if [[ "${1:-}" == "--uninstall" ]]; then
    mode="uninstall"
fi

require_repo() {
    local label="$1" path="$2"
    if [[ ! -d "$path/.git" ]]; then
        echo "warn: $label not present at $path; skipping" >&2
        return 1
    fi
    return 0
}

require_pre_commit() {
    if ! command -v pre-commit >/dev/null 2>&1; then
        echo "error: pre-commit not on PATH. Install with one of:" >&2
        echo "    pipx install pre-commit" >&2
        echo "    pip3 install --user pre-commit" >&2
        exit 1
    fi
}

action_install() {
    local label="$1" repo="$2" config="$3"
    require_repo "$label" "$repo" || return 0
    echo "==> $label: installing pre-commit ($config)"
    ( cd "$repo" && pre-commit install -c "$config" --overwrite )
}

action_uninstall() {
    local label="$1" repo="$2"
    require_repo "$label" "$repo" || return 0
    echo "==> $label: uninstalling pre-commit"
    ( cd "$repo" && pre-commit uninstall )
}

require_pre_commit

if [[ "$mode" == "install" ]]; then
    # gramps-testbed: standard layout, in-place install.
    # The testbed's own hook is the secret guard's: it reads reviewed copies of the root config
    # from the git directory. `pre-commit install --overwrite` would replace it with a hook that
    # reads the checked-out config.
    echo "==> gramps-testbed: activating the secret guard (root config)"
    ( cd "$TESTBED_ROOT" && git show origin/HEAD:.secret-guard/activate.sh | sh )

    action_install "gramps"        "$GRAMPS_REPO" "$GRAMPS_CONFIG"
    action_install "addons-source" "$ADDONS_REPO" "$ADDONS_CONFIG"

    echo
    echo "Done. Hooks active on next 'git commit' in each repo."
    echo "Skip with 'git commit --no-verify' (only if you know why)."
else
    echo "==> gramps-testbed: uninstalling pre-commit"
    ( cd "$TESTBED_ROOT" && pre-commit uninstall )
    action_uninstall "gramps"        "$GRAMPS_REPO"
    action_uninstall "addons-source" "$ADDONS_REPO"
fi
