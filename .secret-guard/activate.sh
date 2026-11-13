#!/bin/sh
# Activate the secret guard (.pre-commit-config.yaml) in this clone. Run the default branch's
# reviewed copy of this script, never the checked-out one:
#
#   pipx install pre-commit==4.7.0
#   s=$(PATH=/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin git show refs/remotes/origin/HEAD:.secret-guard/activate.sh) && /bin/sh -c "$s" activate
#
# Re-run it after .pre-commit-config.yaml or this script changes on the default branch.
# Remove the guard: the same command with `activate --uninstall`. Keep a reviewed earlier hook
# as .git/hooks/pre-commit.legacy and approve it with `activate --approve-legacy`.
#
# Why not `pre-commit install`: its hook reads the checked-out .pre-commit-config.yaml, and
# gitleaks reads a checked-out .gitleaks.toml and .gitleaksignore, so checking out a fork PR
# and committing would run the hooks and scanning policy that branch defines. The hook
# written here reads copies kept in the git directory, pins gitleaks to its built-in rules,
# refuses to commit while a .gitleaksignore is in the checkout or the index, and refuses any
# hook, hooks directory or pre-commit executable that a checked-out branch could replace.
#
# Known limits (accepted, not enforced here):
# - Git LFS: a path a branch routes through LFS is scanned as its pointer, not its content.
# - A core.hooksPath hook outside every checkout is yours: activation checks that it contains
#   the runner line, not what runs before it.
# - An absolute hooks path (or a symlink target) that passes through a checkout directory and
#   back out with `..` is checked at its final target only, not at the directory it crosses.
# - A branch that commits a protected name (.claude/settings.local.json and the like) as a
#   symlink to an ordinary file hides later writes through that name from the path rule;
#   gitleaks still scans the target's content.
# - pre-commit is checked against this repository's worktrees only, not other repositories'.
# - A separate git directory placed inside an ignored path of a worktree is not detected.
# - --uninstall removes only hooks with the managed marker; an older two-line guard hook
#   from before the marker stays and must be deleted by hand.
# - Worktree paths containing a newline are not recognised as checkouts.
# - --no-verify skips every hook; push protection on GitHub is the backstop.
set -eu

# Every command below comes from system directories, never a checkout (a fork could track
# .venv/bin/git). The caller's PATH is consulted once, only to locate pre-commit, which is
# then checked like any other path.
safe_path=/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin
caller_path=$PATH
PATH=$safe_path; export PATH

die() { for line in "$@"; do echo "secret guard: $line" >&2; done; exit 1; }

ref=${SECRET_GUARD_REF:-refs/remotes/origin/HEAD}
case $ref in
  refs/*|HEAD) ;;   # fully qualified: a branch named origin/HEAD cannot shadow it
  *) die "SECRET_GUARD_REF must be HEAD or a full refs/... name, not '$ref'";;
esac

d=$(git rev-parse --path-format=absolute --git-common-dir)
hook="$d/hooks/pre-commit"
mark="# secret-guard managed hook v10"
# The line a core.hooksPath hook (outside every checkout) must contain to run the guard.
req='exec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"'

# --- where branches can write ---------------------------------------------------------------
# Every worktree of this repository is checkout content a branch controls.
# A bare repository's own entry (marked `bare`) is a git directory, not a checkout.
worktrees=$(git worktree list --porcelain |
  awk '/^worktree /{ if (p != "" && !b) print p; p = substr($0, 10); b = 0; next }
       /^bare$/ { b = 1 }
       END { if (p != "" && !b) print p }' |
  while IFS= read -r w; do (cd "$w" 2>/dev/null && pwd -P) || true; done)

# With extensions.worktreeConfig, each worktree may set its own core.hooksPath, and Git in
# that worktree ignores the hook installed here. Refuse any such override.
if [ "$(git config --bool extensions.worktreeConfig 2>/dev/null || true)" = true ]; then
  overrides=$(printf '%s\n' "$worktrees" | while IFS= read -r w; do
    [ -n "$w" ] || continue
    if git -C "$w" config --worktree --get core.hooksPath >/dev/null 2>&1; then echo "$w"; fi
  done)
  if [ -n "$overrides" ] && [ "${1:-}" != --uninstall ]; then
    die "these worktrees set their own core.hooksPath (extensions.worktreeConfig), so Git there" \
      "would not run the guard:" "$overrides" \
      "Unset it in each (git -C <worktree> config --worktree --unset core.hooksPath), then re-run."
  fi
fi

git_dir_real=$(cd "$d" && pwd -P)

# in_worktree PATH (physical): PATH lies in a worktree of this repository. Paths in the git
# directory are not checkout content, unless a worktree itself lives inside the git directory.
in_worktree() {
  printf '%s\n' "$worktrees" | while IFS= read -r w; do
    [ -n "$w" ] || continue
    case $1/ in
      "$w"/*)
        case $w/ in "$git_dir_real"/*) echo yes; break;; esac
        case $1/ in "$git_dir_real"/*) continue;; esac
        echo yes; break;;
    esac
  done | grep -q yes
}

# in_any_checkout PATH (physical directory): PATH lies in the work tree of any repository.
in_any_checkout() {
  [ "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]
}

# phys PATH: the physical form of a path whose components are no longer symlinks.
phys() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P)
  else printf '%s/%s\n' "$(cd "$(dirname -- "$1")" && pwd -P)" "$(basename -- "$1")"; fi
}

# chain_unsafe MODE PATH: follow PATH one symlink hop at a time (up to 40). True when the place
# any link sits, or the final target, lies in a checkout, or PATH cannot be followed. MODE
# "any" also counts other repositories' work trees (for hooks); "repo" only this repository's
# worktrees (for the pre-commit executable).
chain_unsafe() {
  mode=$1; p=$2
  case $p in /*) ;; *) p="$(pwd -P)/$p";; esac
  hops=0
  while :; do
    hops=$((hops + 1)); [ "$hops" -le 40 ] || return 0
    acc=""; rest=""; link=""
    old_ifs=$IFS; IFS=/; set -f
    for part in $p; do
      [ -n "$part" ] || continue
      if [ -n "$link" ]; then rest="$rest/$part"; continue; fi
      acc="$acc/$part"
      [ -L "$acc" ] && link=$acc
    done
    IFS=$old_ifs; set +f
    if [ -z "$link" ]; then
      [ -e "$p" ] || [ -L "$p" ] || return 0
      final=$(phys "$p") || return 0
      in_worktree "$final" && return 0
      if [ "$mode" = any ]; then
        dir=$final; [ -d "$dir" ] || dir=$(dirname -- "$final")
        in_any_checkout "$dir" && return 0
      fi
      return 1
    fi
    at=$(cd "$(dirname -- "$link")" 2>/dev/null && pwd -P) || return 0
    in_worktree "$at" && return 0
    if [ "$mode" = any ] && in_any_checkout "$at"; then return 0; fi
    t=$(readlink -- "$link") || return 0
    case $t in /*) ;; *) t="$(dirname -- "$link")/$t";; esac
    p="$t$rest"
  done
}

# --- core.hooksPath ---------------------------------------------------------------------------
hp=""
hooks_path=""
hooks_set=no
if git config --get core.hooksPath >/dev/null 2>&1; then
  hooks_set=yes
  hooks_path=$(git config --path core.hooksPath)   # --path: ~ expands as Git does
  [ -n "$hooks_path" ] || die "core.hooksPath is set but empty, so Git runs no hooks at all;" \
    "unset it (git config --unset core.hooksPath) or point it at a directory, then re-run."
  case $hooks_path in
    /*) hp=$hooks_path;;
    *) die "core.hooksPath ($hooks_path) is relative, so each worktree resolves it to a different" \
         "directory; set an absolute path outside every checkout, then re-run.";;
  esac
fi

if [ "${1:-}" = --uninstall ]; then
  if [ -n "$hp" ] && grep -qxF "$req" "$hp/pre-commit" 2>/dev/null; then
    die "$hp/pre-commit still runs the guard; remove this line from it first:" "  $req"
  fi
  if [ -f "$hook" ] && [ ! -L "$hook" ] && grep -q '^# secret-guard managed hook' "$hook"; then
    rm -f "$hook"
    if [ -e "$hook.legacy" ]; then mv "$hook.legacy" "$hook"; fi
  fi
  rm -f "$d/secret-guard-run" "$d/secret-guard.yaml" "$d/secret-guard-gitleaks.toml" \
    "$d/secret-guard-pre-commit" "$d/secret-guard-legacy.approved"
  echo "secret guard removed"
  exit 0
fi

# --- validate everything before changing anything -------------------------------------------
pc=$(PATH=$caller_path; command -v pre-commit) || die "pre-commit not found; pipx install pre-commit==4.7.0"
case $pc in /*) ;; *) die "pre-commit resolves to '$pc', not an absolute path";; esac
if chain_unsafe repo "$pc"; then
  die "pre-commit ($pc) is in, or resolves through, a checkout of this repository, where a" \
    "branch can replace it; put the pipx (or system) pre-commit first on PATH and re-run."
fi
pc=$(readlink -f -- "$pc")

legacy_sum=""
if [ "$hooks_set" = yes ]; then
  if [ ! -d "$hp" ] || chain_unsafe any "$hp" || { [ -e "$hp/pre-commit" ] && chain_unsafe any "$hp/pre-commit"; }; then
    die "core.hooksPath ($hooks_path), or its pre-commit hook, is in or resolves through a" \
      "checkout of this repository (or does not resolve), so a branch could replace it. Point" \
      "core.hooksPath at a directory outside every checkout, or unset it and copy any hook you" \
      "still want into $d/hooks after reviewing it, then re-run."
  fi
  if ! { [ -x "$hp/pre-commit" ] && grep -qxF "$req" "$hp/pre-commit"; }; then
    die "core.hooksPath is $hooks_path, so a hook in $d/hooks would never run." \
      "Make $hooks_path/pre-commit executable and end it with this exact line:" "  $req"
  fi
else
  # A clone made with an empty template has no hooks directory: check where it would go
  # (the git directory itself), then create it, so the checks below see a real directory.
  if [ ! -e "$d/hooks" ] && [ ! -L "$d/hooks" ]; then
    chain_unsafe any "$d" && die "the git directory $d is in or resolves into a checkout; refusing."
    mkdir "$d/hooks"
  fi
  if chain_unsafe any "$d/hooks" || { { [ -e "$hook" ] || [ -L "$hook" ]; } && chain_unsafe any "$hook"; }; then
    die "$d/hooks, or the pre-commit hook in it, is in or resolves into a checkout of this" \
      "repository, so a branch could replace it. Make $d/hooks a plain directory and remove" \
      "the symlinked hook, then re-run."
  fi
  if [ -L "$hook" ]; then
    die "$hook is a symlink; review its target, replace it with a plain file or remove it, then re-run."
  fi
  if [ -e "$hook" ]; then
    # Only hooks this guard (or pre-commit itself) generated are replaced without review.
    if ! { grep -q '^# secret-guard managed hook' "$hook" ||
           grep -q '^# File generated by pre-commit' "$hook" ||
           grep -q '^# Secret guard, written by .secret-guard/activate.sh' "$hook" ||
           { [ "$(wc -l < "$hook")" -eq 2 ] &&
             grep -qx 'exec pre-commit run --config ".*/secret-guard.yaml" --hook-stage pre-commit' "$hook"; }; }; then
      die "$hook is a custom hook. Review it (does it run anything from a checkout?), then either" \
        "delete it, or move it to $hook.legacy and re-run with --approve-legacy to keep it" \
        "running before the guard."
    fi
  fi
  if [ -e "$hook.legacy" ] || [ -L "$hook.legacy" ]; then
    [ -L "$hook.legacy" ] && die "$hook.legacy is a symlink; replace it with a reviewed plain file."
    legacy_sum=$(git hash-object -- "$hook.legacy")
    approved=""
    if [ -f "$d/secret-guard-legacy.approved" ]; then read -r approved < "$d/secret-guard-legacy.approved" || true; fi
    if [ "$approved" != "$legacy_sum" ] && [ "${1:-}" != --approve-legacy ]; then
      die "$hook.legacy would run before the guard on every commit. Review it (does it run" \
        "anything from a checkout?), then re-run with: activate --approve-legacy, or delete it."
    fi
  fi
fi

# --- write ----------------------------------------------------------------------------------
git show "$ref:.pre-commit-config.yaml" > "$d/secret-guard.yaml"
# Gitleaks' built-in rules. GITLEAKS_CONFIG outranks a .gitleaks.toml in the checkout.
printf '[extend]\nuseDefault = true\n' > "$d/secret-guard-gitleaks.toml"
# Recorded so commits outside the shell (or virtualenv) that activated still find it.
printf '%s\n' "$pc" > "$d/secret-guard-pre-commit"

# The runner works out every path when it runs; nothing about this clone is written into it.
{
  echo '#!/bin/sh'
  echo '# Secret guard runner, written by .secret-guard/activate.sh. Reads the reviewed copies in'
  echo '# the git directory, never the checkout, and takes commands only from system directories.'
  echo "PATH=$safe_path; export PATH"
  cat <<'EOF'
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
read -r pc < "$d/secret-guard-pre-commit"
GITLEAKS_CONFIG="$d/secret-guard-gitleaks.toml" exec "$pc" run --config "$d/secret-guard.yaml" --hook-stage pre-commit
EOF
} > "$d/secret-guard-run.tmp"
chmod +x "$d/secret-guard-run.tmp"
mv -f "$d/secret-guard-run.tmp" "$d/secret-guard-run"

if [ "$hooks_set" = yes ]; then
  echo "secret guard: copies refreshed from $ref; $hooks_path/pre-commit runs the guard"
  exit 0
fi

if [ -n "$legacy_sum" ] && [ "${1:-}" = --approve-legacy ]; then
  printf '%s\n' "$legacy_sum" > "$d/secret-guard-legacy.approved"
  echo "secret guard: approved $hook.legacy (git hash $legacy_sum); it runs before the guard"
fi

mkdir -p "$d/hooks"
tmp="$d/hooks/.pre-commit.secret-guard.tmp"
{
  echo '#!/bin/sh'
  echo "$mark"
  echo '# Written by .secret-guard/activate.sh. A reviewed pre-commit.legacy, approved by its git'
  echo '# hash, runs first, so the guard scans the index as it will be committed.'
  echo "PATH=$safe_path; export PATH"
  cat <<'EOF'
d=$(git rev-parse --path-format=absolute --git-common-dir)
if [ -e "$d/hooks/pre-commit.legacy" ]; then
  approved=""
  if [ -f "$d/secret-guard-legacy.approved" ]; then read -r approved < "$d/secret-guard-legacy.approved" || true; fi
  if [ "$(git hash-object -- "$d/hooks/pre-commit.legacy")" != "$approved" ]; then
    echo "secret guard: hooks/pre-commit.legacy changed since it was approved; re-run activation" >&2
    exit 1
  fi
  "$d/hooks/pre-commit.legacy" "$@" || exit $?
fi
exec "$d/secret-guard-run" "$@"
EOF
} > "$tmp"
chmod +x "$tmp"
mv -f "$tmp" "$hook"   # replaces the file itself, never a symlink's target
echo "secret guard active (config from $ref: $d/secret-guard.yaml)"
