#!/bin/sh
# Activate the secret guard (.pre-commit-config.yaml) in this clone. Run the default branch's
# reviewed copy of this script, never the checked-out one:
#
#   pipx install pre-commit==4.7.0
#   s=$(git show refs/remotes/origin/HEAD:.secret-guard/activate.sh) && sh -c "$s" activate
#
# Re-run it after .pre-commit-config.yaml or this script changes on the default branch.
# Remove the guard: the same command with `activate --uninstall`. Keep a reviewed earlier hook
# as .git/hooks/pre-commit.legacy and approve it with `activate --approve-legacy`.
#
# Why not `pre-commit install`: its hook reads the checked-out .pre-commit-config.yaml, and
# gitleaks reads a checked-out .gitleaks.toml and .gitleaksignore, so checking out a fork PR
# and committing would run the hooks and scanning policy that branch defines. The hook
# written here reads copies kept in the git directory, pins gitleaks to its built-in rules,
# and refuses to commit while a .gitleaksignore is in the checkout or the index.
set -eu

ref=${SECRET_GUARD_REF:-refs/remotes/origin/HEAD}
case $ref in
  refs/*|HEAD) ;;   # fully qualified: a branch named origin/HEAD cannot shadow it
  *) echo "secret guard: SECRET_GUARD_REF must be HEAD or a full refs/... name, not '$ref'" >&2; exit 1;;
esac

d=$(git rev-parse --path-format=absolute --git-common-dir)
top=$(git rev-parse --show-toplevel)
hook="$d/hooks/pre-commit"
mark="# secret-guard managed hook v5"
# The line a core.hooksPath hook (outside the checkout) must contain to run the guard.
req='exec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"'

# inside PATH: true when PATH (file or directory, symlinks and .. resolved) lies in the checkout.
real_top=$(cd "$top" && pwd -P)
# Both the entry itself (its directory resolved) and its final target are checked: a symlink
# that sits in the checkout can be replaced by a branch even if it points outside.
inside() {
  r=$(readlink -f -- "$1" 2>/dev/null) || return 0   # unresolvable: treat as inside (refuse)
  case $r/ in "$real_top"/*) return 0;; esac
  p=$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 0
  case $p/ in "$real_top"/*) return 0;; esac
  return 1
}

hooks_path=$(git config --path core.hooksPath || true)   # --path: ~ expands as Git does
hp=""
if [ -n "$hooks_path" ]; then
  case $hooks_path in
    /*) hp=$hooks_path;;
    *) hp="$top/$hooks_path";;
  esac
fi

if [ "${1:-}" = --uninstall ]; then
  if [ -n "$hp" ] && grep -qxF "$req" "$hp/pre-commit" 2>/dev/null; then
    echo "secret guard: $hp/pre-commit still runs the guard; remove this line from it first:" >&2
    echo "  $req" >&2
    exit 1
  fi
  if grep -qxF "$mark" "$hook" 2>/dev/null || grep -q 'secret-guard managed hook' "$hook" 2>/dev/null; then
    rm -f "$hook"
    if [ -e "$hook.legacy" ]; then mv "$hook.legacy" "$hook"; fi
  fi
  rm -f "$d/secret-guard-run" "$d/secret-guard.yaml" "$d/secret-guard-gitleaks.toml" "$d/secret-guard-pre-commit" "$d/secret-guard-legacy.approved"
  echo "secret guard removed"
  exit 0
fi

pc=$(command -v pre-commit) || {
  echo "secret guard: pre-commit not found; pipx install pre-commit==4.7.0" >&2; exit 1; }
case $pc in
  /*) ;;
  *) echo "secret guard: pre-commit resolves to '$pc', not an absolute path" >&2; exit 1;;
esac
if inside "$pc"; then
  echo "secret guard: pre-commit ($pc) is inside the checkout, where a branch can replace it;" >&2
  echo "put the pipx (or system) pre-commit first on PATH and re-run." >&2
  exit 1
fi
pc=$(readlink -f -- "$pc")

# Refuse a hooks directory, or a pre-commit hook in it, that lies in the checkout (symlinks
# and .. resolved), before writing anything: a checked-out branch could rewrite it.
if [ -n "$hp" ]; then
  if [ ! -d "$hp" ] || inside "$hp" || { [ -e "$hp/pre-commit" ] && inside "$hp/pre-commit"; }; then
    echo "secret guard: core.hooksPath ($hooks_path) or its pre-commit hook is inside the checkout" >&2
    echo "(or does not resolve), so a checked-out branch could replace it. Point core.hooksPath at a" >&2
    echo "directory outside the checkout, or unset it (git config --unset core.hooksPath) and copy" >&2
    echo "any hook you still want into $d/hooks after reviewing it, then re-run." >&2
    exit 1
  fi
fi

git show "$ref:.pre-commit-config.yaml" > "$d/secret-guard.yaml"
# Gitleaks' built-in rules. GITLEAKS_CONFIG outranks a .gitleaks.toml in the checkout.
printf '[extend]\nuseDefault = true\n' > "$d/secret-guard-gitleaks.toml"
# Recorded so commits outside the shell (or virtualenv) that activated still find it.
printf '%s\n' "$pc" > "$d/secret-guard-pre-commit"

# The runner works out every path when it runs; nothing about this clone is written into it.
cat > "$d/secret-guard-run" <<'EOF'
#!/bin/sh
# Secret guard runner, written by .secret-guard/activate.sh. Reads the reviewed copies in the
# git directory, never the checkout.
set -eu
d=$(git rev-parse --path-format=absolute --git-common-dir)
top=$(git rev-parse --show-toplevel)
# gitleaks loads <checkout>/.gitleaksignore unconditionally, and pre-commit restores the
# indexed copy while it hides unstaged changes, so refuse one in either place.
if [ -e "$top/.gitleaksignore" ] || git cat-file -e :.gitleaksignore 2>/dev/null; then
  echo "secret guard: refusing to commit while .gitleaksignore is in the checkout or the index;" >&2
  echo "gitleaks would load its suppressions. Remove and unstage it (git rm --cached), or commit" >&2
  echo "with --no-verify after reviewing it." >&2
  exit 1
fi
pc=$(cat "$d/secret-guard-pre-commit")
GITLEAKS_CONFIG="$d/secret-guard-gitleaks.toml" exec "$pc" run --config "$d/secret-guard.yaml" --hook-stage pre-commit
EOF
chmod +x "$d/secret-guard-run"

if [ -n "$hp" ]; then
  if [ -x "$hp/pre-commit" ] && grep -qxF "$req" "$hp/pre-commit"; then
    echo "secret guard: copies refreshed from $ref; $hooks_path/pre-commit runs the guard"
    exit 0
  fi
  echo "secret guard: core.hooksPath is $hooks_path, so a hook in $d/hooks would never run." >&2
  echo "Make $hooks_path/pre-commit executable and end it with this exact line:" >&2
  echo "  $req" >&2
  exit 1
fi

mkdir -p "$d/hooks"
if [ -e "$hook" ] && ! grep -q 'secret-guard managed hook' "$hook"; then
  if grep -q 'File generated by pre-commit' "$hook" || grep -q 'secret-guard.yaml' "$hook"; then
    rm -f "$hook"   # pre-commit's own hook (reads the checkout) or an older guard hook
  else
    # An unknown hook may run checkout content; keeping it is the user's call, after review.
    echo "secret guard: $hook is a custom hook. Review it (does it run anything from the checkout?)," >&2
    echo "then either delete it, or move it to $hook.legacy and re-run with --approve-legacy to keep" >&2
    echo "it running before the guard." >&2
    exit 1
  fi
fi

# A pre-commit.legacy runs before the guard only when you approved this exact content.
if [ -e "$hook.legacy" ]; then
  sum=$(git hash-object -- "$hook.legacy")
  if [ "$(cat "$d/secret-guard-legacy.approved" 2>/dev/null || true)" != "$sum" ]; then
    if [ "${2:-}" = --approve-legacy ] || [ "${1:-}" = --approve-legacy ]; then
      printf '%s\n' "$sum" > "$d/secret-guard-legacy.approved"
      echo "secret guard: approved $hook.legacy (git hash $sum); it runs before the guard"
    else
      echo "secret guard: $hook.legacy will run before the guard on every commit. Review it (does it" >&2
      echo "run anything from the checkout?), then re-run with: activate --approve-legacy" >&2
      echo "or delete it." >&2
      exit 1
    fi
  fi
fi

cat > "$hook" <<EOF
#!/bin/sh
$mark
# Written by .secret-guard/activate.sh. A reviewed pre-commit.legacy, if you placed one, runs
# first, so the guard scans the index as it will be committed.
EOF
cat >> "$hook" <<'EOF'
d=$(git rev-parse --path-format=absolute --git-common-dir)
if [ -e "$d/hooks/pre-commit.legacy" ]; then
  # Runs only the content approved at activation; anything else stops the commit.
  if [ "$(git hash-object -- "$d/hooks/pre-commit.legacy")" != "$(cat "$d/secret-guard-legacy.approved" 2>/dev/null)" ]; then
    echo "secret guard: hooks/pre-commit.legacy changed since it was approved; re-run activation" >&2
    exit 1
  fi
  "$d/hooks/pre-commit.legacy" "$@" || exit $?
fi
exec "$d/secret-guard-run" "$@"
EOF
chmod +x "$hook"
echo "secret guard active (config from $ref: $d/secret-guard.yaml)"
