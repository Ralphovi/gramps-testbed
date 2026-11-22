#!/usr/bin/env bash
# Scenario tests for .secret-guard/activate.sh and the guard's .pre-commit-config.yaml.
# Run from anywhere: bash .secret-guard/test-activate.sh
# Needs git, pre-commit (pipx install pre-commit==4.7.0) and network access the first time,
# when pre-commit builds gitleaks. Works in a temporary directory with the user's and the
# system's git configuration switched off; prints PASS/FAIL per scenario and exits 1 on any
# FAIL.
set -u
SG=$(cd "$(dirname -- "$0")/.." && pwd -P)
T=$(mktemp -d) && [ -n "$T" ] && [ -d "$T" ] || { echo "cannot create a temporary directory" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = guard test\n\temail = guard-test@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
fails=0
GIT=$(command -v git) || { echo 'git not found' >&2; exit 1; }
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails + 1)); }
tok() { echo "t=ghp_$(head -c 60 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 36)"; }
act() { s=$(PATH=/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin git show refs/remotes/origin/HEAD:.secret-guard/activate.sh) && /bin/sh -c "$s" activate "$@"; }
commits() { git rev-list --count HEAD; }

git init -q -b main up; cp "$SG/.pre-commit-config.yaml" up/.pre-commit-config.yaml
mkdir up/.secret-guard; cp "$SG/.secret-guard/activate.sh" up/.secret-guard/activate.sh
git -C up add .; git -C up commit -qm init

# A: custom hook kept, runs FIRST; a legacy hook that stages .env is caught
git clone -q up a; cd a
printf '#!/bin/sh\necho x > .env\ngit add -f .env\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
act >/dev/null 2>&1 && bad "A0 custom hook kept silently" || ok "A0 custom hook refused until reviewed"
mv .git/hooks/pre-commit .git/hooks/pre-commit.legacy
act >/dev/null 2>&1 && bad "A1 legacy enabled without approval" || ok "A1 legacy needs approval"
act --approve-legacy >/dev/null || bad "A activation"; echo a > a; git add a; n=$(commits); git commit -qm a >/dev/null 2>&1
[ "$(commits)" = "$n" ] && ok "A legacy hook runs first; the .env it stages is blocked" || bad A
git reset -q; rm -f .env; rm .git/hooks/pre-commit.legacy
# B: re-run keeps a single managed hook, no new legacy
act >/dev/null && [ ! -e .git/hooks/pre-commit.legacy ] && ok "B re-run harmless" || bad B
# C: token blocked
tok > l; git add l; n=$(commits); git commit -qm l >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "C token blocked" || bad C; git reset -q; rm l
# D: branch with evil config + .gitleaks.toml allowlist
git checkout -q -b evil
printf '[allowlist]\nregexes = ["ghp_.*"]\npaths = [".*"]\n' > .gitleaks.toml
printf 'repos:\n  - repo: local\n    hooks:\n      - id: pwn\n        name: PWNED\n        language: system\n        entry: touch %s/PWNED\n        always_run: true\n' "$T" > .pre-commit-config.yaml
git add .; git commit -qm evil >/dev/null 2>&1; tok > l; git add l; n=$(commits); git commit -qm l >/dev/null 2>&1
[ "$(commits)" = "$n" ] && [ ! -e "$T/PWNED" ] && ok "D evil config not run, .gitleaks.toml allowlist ignored" || bad D; git reset -q; rm l
# E: .gitleaksignore refused
echo 'l:github-pat:1' > .gitleaksignore; git add .gitleaksignore; n=$(commits); git commit -qm gi >/dev/null 2>&1
[ "$(commits)" = "$n" ] && ok "E .gitleaksignore refused" || bad E; git reset -q; rm .gitleaksignore; git checkout -q -f main
# F: worktree
git worktree add -q "$T/wt" -b w
if (cd "$T/wt" && tok > l && git add l && n=$(git rev-list --count HEAD) && { git commit -qm l >/dev/null 2>&1; [ "$(git rev-list --count HEAD)" = "$n" ]; }); then ok "F worktree blocks token"; else bad F; fi
# J: uninstall restores a kept hook
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit.legacy; chmod +x .git/hooks/pre-commit.legacy
act --uninstall >/dev/null && [ -x .git/hooks/pre-commit ] && ! grep -q 'secret-guard' .git/hooks/pre-commit && [ ! -e .git/secret-guard-run ] && ok "J uninstall restores kept hook" || bad J
rm -f .git/hooks/pre-commit
# L: an older guard hook (v1 printf style) is replaced, not kept as legacy
printf '#!/bin/sh\nexec pre-commit run --config "%s/secret-guard.yaml" --hook-stage pre-commit\n' "$PWD/.git" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
act >/dev/null && [ ! -e .git/hooks/pre-commit.legacy ] && grep -q 'managed hook v11' .git/hooks/pre-commit && ok "L older guard hook replaced" || bad L
cd "$T"

# G: core.hooksPath
git clone -q up g; cd g; mkdir -p hooks "$T/ghooks"; git config core.hooksPath hooks
printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > hooks/pre-commit; chmod +x hooks/pre-commit
act >/dev/null 2>&1 && bad "G0 in-checkout hooksPath accepted" || ok "G0 in-checkout hooksPath refused"
git config core.hooksPath "$T/ghooks"; rm -r hooks
printf '#!/bin/sh\n# TODO secret-guard.yaml\nexit 0\n' > "$T/ghooks/pre-commit"; chmod +x "$T/ghooks/pre-commit"
act >/dev/null 2>&1 && bad "G1 comment-only hook accepted" || ok "G1 comment-only hook refused"
printf '#!/bin/sh\nexec pre-commit run --config "$(git rev-parse --git-common-dir)/secret-guard.yaml"\n' > "$T/ghooks/pre-commit"
act >/dev/null 2>&1 && bad "G2 old-style hook accepted" || ok "G2 old-style hook (no policy) refused"
printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > "$T/ghooks/pre-commit"
act >/dev/null 2>&1 && ok "G3 exact invocation accepted" || bad G3
tok > l; git add l; n=$(commits); git commit -qm l >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "G4 hooksPath hook blocks token" || bad G4
git reset -q; rm l
act --uninstall >/dev/null 2>&1 && bad "G5 uninstall left hooksPath hook dangling" || ok "G5 uninstall refused while hooksPath hook runs guard"
cd "$T"

# H: clone path with shell metacharacters
git clone -q up 'h$budget`x`'; cd 'h$budget`x`'; act >/dev/null
echo ok > ok; git add ok; n=$(commits); git commit -qm ok >/dev/null 2>&1; a=$(commits)
tok > l; git add l; git commit -qm l >/dev/null 2>&1; b=$(commits)
[ "$a" = $((n+1)) ] && [ "$b" = "$a" ] && ok "H metacharacter path: clean commit passes, token blocked" || bad "H ($n $a $b)"
cd "$T"

# I: pre-commit found only on the activating PATH
git clone -q up i; cd i; mkdir -p "$T/ibin"; ln -sf "$(command -v pre-commit)" "$T/ibin/pre-commit"
PATH="$T/ibin:/usr/bin:/bin" act >/dev/null || bad "I activation"
echo ok > ok; git add ok; n=$(commits); PATH=/usr/bin:/bin git commit -qm ok >/dev/null 2>&1
[ "$(commits)" = $((n+1)) ] && ok "I recorded pre-commit used outside the activating PATH" || bad I
cd "$T"

# K: failed retrieval is an error
git init -q -b main k; cd k; (s=$(git show origin/HEAD:.secret-guard/activate.sh 2>/dev/null) && sh -c "$s" activate) && bad "K empty script succeeded" || ok "K failed retrieval fails"

# M: staged .gitleaksignore deleted only from the worktree
cd "$T/a"; git checkout -q -b m; echo 'x:github-pat:1' > .gitleaksignore; git add .gitleaksignore; rm .gitleaksignore
echo y > y; git add y; n=$(commits); git commit -qm m >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "M staged-only .gitleaksignore refused" || bad M; git reset -q; git checkout -q -f main
# N: inline gitleaks:allow ignored
tok | sed 's/$/  # gitleaks:allow/' > c.py; git add c.py; n=$(commits); git commit -qm n >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "N gitleaks:allow comment ignored" || bad N; git reset -q; rm c.py
# O: .gitattributes -diff does not hide a staged token
git checkout -q -b o; echo 'app.cfg -diff' > .gitattributes; git add .gitattributes; git commit -qm attrs >/dev/null 2>&1
tok > app.cfg; git add app.cfg; n=$(commits); git commit -qm o >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "O -diff attribute does not hide token" || bad O; git reset -q; rm app.cfg; git checkout -q -f main
# P: a local branch named origin/HEAD does not shadow the remote ref
git checkout -q -b origin/HEAD; printf '#!/bin/sh\ntouch %s/PWNED2\n' "$T" > .secret-guard/activate.sh; git commit -qam evil >/dev/null 2>&1; git checkout -q main
act >/dev/null 2>&1 && [ ! -e "$T/PWNED2" ] && ok "P branch named origin/HEAD not executed" || bad P
SECRET_GUARD_REF=origin/HEAD sh -c "$(git show refs/remotes/origin/HEAD:.secret-guard/activate.sh)" activate >/dev/null 2>&1 && bad "P2 short ref accepted" || ok "P2 short SECRET_GUARD_REF refused"
cd "$T"

# Q: relative hooksPath to a sibling directory is outside; a symlink into the checkout is inside
cd "$T"; git clone -q up q; mkdir -p shared-hooks
printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > shared-hooks/pre-commit; chmod +x shared-hooks/pre-commit
cd q; git config core.hooksPath ../shared-hooks; act >/dev/null 2>&1 && bad "Q1 relative hooksPath accepted" || ok "Q1 relative hooksPath refused"
git config core.hooksPath "$T/shared-hooks"; act >/dev/null 2>&1 && ok "Q1b absolute sibling hooksPath accepted" || bad Q1b
mkdir -p inside; cp ../shared-hooks/pre-commit inside/; ln -s "$PWD/inside" "$T/link-in"; git config core.hooksPath "$T/link-in"
act >/dev/null 2>&1 && bad "Q2 symlink into checkout accepted" || ok "Q2 symlink into checkout refused"
git config core.hooksPath "$T/does-not-exist"; act >/dev/null 2>&1 && bad "Q3 missing dir accepted" || ok "Q3 unresolvable hooksPath refused"
cd "$T"

# R: a staged file named --help (marked -diff) is still scanned
cd "$T/a"; git checkout -q -b r; echo -- '--help -diff' > .gitattributes; printf '%s\n' '--help -diff' > .gitattributes; git add .gitattributes; git commit -qm attrs >/dev/null 2>&1
tok > ./--help; git add -- ./--help; n=$(commits); git commit -qm r >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "R dash-named -diff file scanned" || bad R; git reset -q; rm -- ./--help; git checkout -q -f main
# S: a legacy hook changed after approval stops the commit
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit.legacy; chmod +x .git/hooks/pre-commit.legacy; act --approve-legacy >/dev/null
echo s > s; git add s; n=$(commits); git commit -qm s >/dev/null 2>&1; a1=$(commits)
printf '#!/bin/sh\necho changed\nexit 0\n' > .git/hooks/pre-commit.legacy; echo s2 > s2; git add s2; git commit -qm s2 >/dev/null 2>&1
[ "$a1" = $((n+1)) ] && [ "$(commits)" = "$a1" ] && ok "S approved legacy runs; changed legacy stops commit" || bad "S ($n $a1 $(commits))"
git reset -q; rm -f s2 .git/hooks/pre-commit.legacy .git/secret-guard-legacy.approved
# T: pre-commit inside the checkout is refused
mkdir -p bin; ln -sf "$(command -v pre-commit)" bin/pre-commit
PATH="$PWD/bin:$PATH" act >/dev/null 2>&1 && bad "T checkout pre-commit accepted" || ok "T pre-commit inside checkout refused"; rm -r bin
# U: ~ in core.hooksPath is expanded
cd "$T"; git clone -q up u; cd u; H="$T/home"; mkdir -p "$H/hooks"
printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > "$H/hooks/pre-commit"; chmod +x "$H/hooks/pre-commit"
git config core.hooksPath '~/hooks'; HOME="$H" act >/dev/null 2>&1 && ok "U ~/hooks accepted" || bad U
# V: hook FILE symlinked into the checkout is refused
mkdir -p "$T/vh" tracked; cp "$H/hooks/pre-commit" tracked/pre-commit; ln -sf "$PWD/tracked/pre-commit" "$T/vh/pre-commit"; git config core.hooksPath "$T/vh"
act >/dev/null 2>&1 && bad "V hook file symlink into checkout accepted" || ok "V hook file symlink into checkout refused"
cd "$T"

# ---- round 3 ----
cd "$T"
# W1: empty core.hooksPath refused
git clone -q up w1; cd w1; git config core.hooksPath ""; act >/dev/null 2>&1 && bad "W1 empty hooksPath accepted" || ok "W1 empty hooksPath refused"; cd "$T"
# W2: default .git/hooks symlinked into the checkout refused
git clone -q up w2; cd w2; mkdir tracked-hooks; rm -rf .git/hooks; ln -s ../tracked-hooks .git/hooks
act >/dev/null 2>&1 && bad "W2 symlinked .git/hooks accepted" || ok "W2 .git/hooks into checkout refused"; cd "$T"
# W3: .git/hooks/pre-commit symlinked to a tracked file carrying the marker refused, target untouched
git clone -q up w3; cd w3; printf '#!/bin/sh\n# secret-guard managed hook v11\nexit 0\n' > th; ln -sf "$PWD/th" .git/hooks/pre-commit
act >/dev/null 2>&1 && bad "W3 symlinked hook accepted" || { grep -q 'exit 0' th && ok "W3 symlinked hook refused, target untouched" || bad "W3 target modified"; }; cd "$T"
# W4: tracked ancestor symlink in hooksPath (link/hooks, link -> outside) refused
mkdir -p "$T/outside/hooks"; printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > "$T/outside/hooks/pre-commit"; chmod +x "$T/outside/hooks/pre-commit"
git clone -q up w4; cd w4; ln -s "$T/outside" link; git config core.hooksPath link/hooks
act >/dev/null 2>&1 && bad "W4 ancestor symlink accepted" || ok "W4 checkout ancestor symlink refused"; cd "$T"
# W5/W6: hooksPath or pre-commit inside another linked worktree refused
git clone -q up w5; cd w5; git worktree add -q "$T/w5b" -b other; mkdir -p "$T/w5b/hk" "$T/w5b/bin"; cp "$T/outside/hooks/pre-commit" "$T/w5b/hk/"; ln -sf "$(command -v pre-commit)" "$T/w5b/bin/pre-commit"
git config core.hooksPath "$T/w5b/hk"; act >/dev/null 2>&1 && bad "W5 hooksPath in sibling worktree accepted" || ok "W5 hooksPath in another worktree refused"
git config --unset core.hooksPath; PATH="$T/w5b/bin:$PATH" act >/dev/null 2>&1 && bad "W6 pre-commit in sibling worktree accepted" || ok "W6 pre-commit in another worktree refused"; cd "$T"
# W7: a custom hook that mentions secret-guard.yaml is not deleted
git clone -q up w7; cd w7; printf '#!/bin/sh\nmake lint\nexec pre-commit run --config .git/secret-guard.yaml\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
act >/dev/null 2>&1 && bad "W7 custom hook replaced" || { grep -q 'make lint' .git/hooks/pre-commit && ok "W7 custom hook referencing guard kept, review asked" || bad "W7 hook lost"; }; cd "$T"
# W8: older guard hook stays when legacy approval is missing
git clone -q up w8; cd w8; printf '#!/bin/sh\nexec pre-commit run --config "%s/secret-guard.yaml" --hook-stage pre-commit\n' "$PWD/.git" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit.legacy; chmod +x .git/hooks/pre-commit.legacy
act >/dev/null 2>&1 && bad "W8 unapproved legacy accepted" || { grep -q 'secret-guard.yaml' .git/hooks/pre-commit && ok "W8 existing guard kept when approval fails" || bad "W8 guard removed"; }; cd "$T"
# W9: working-tree-encoding UTF-16 does not hide a staged token
cd "$T/a"; git checkout -q -b w9; printf 'enc.txt -diff working-tree-encoding=UTF-16LE\n' > .gitattributes; git add .gitattributes; git commit -qm a >/dev/null 2>&1
tok | iconv -f UTF-8 -t UTF-16LE > enc.txt; git add enc.txt; n=$(commits); git commit -qm w9 >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "W9 UTF-16 working-tree-encoding token blocked" || bad W9; git reset -q; rm -f enc.txt; git checkout -q -f main
# W10: a checkout-local cat/git first on PATH is not executed by the hook
mkdir -p .venv/bin; for c in cat git sh; do printf '#!/bin/sh\ntouch %s/PWNED_%s\nexit 0\n' "$T" "$c" > .venv/bin/$c; chmod +x .venv/bin/$c; done
echo w10 > w10; "$GIT" add w10; n=$(commits); PATH="$PWD/.venv/bin:$PATH" "$GIT" commit -qm w10 >/dev/null 2>&1
if ls "$T"/PWNED_* >/dev/null 2>&1; then bad "W10 checkout PATH command ran"
elif [ "$(commits)" != $((n+1)) ]; then bad "W10 clean commit did not go through"
else ok "W10 checkout-local cat/git/sh not used by the hook"; fi; rm -rf .venv
cd "$T"

# ---- v7 ----
# X1: a staged file named 0:payload.txt is scanned as itself, not as payload.txt
cd "$T/a"; echo clean > payload.txt; git add payload.txt; git commit -qm p >/dev/null 2>&1
tok > '0:payload.txt'; git add -- '0:payload.txt'; n=$(commits); git commit -qm x1 >/dev/null 2>&1
[ "$(commits)" = "$n" ] && ok "X1 colon filename scanned as itself" || bad X1; git reset -q; rm -f -- '0:payload.txt'
# X2: a checkout-local git first on PATH is not executed by activation
mkdir -p .venv/bin; printf '#!/bin/sh\ntouch %s/PWNED_actgit\nexec %s "$@"\n' "$T" "$GIT" > .venv/bin/git; chmod +x .venv/bin/git
PATH="$PWD/.venv/bin:$PATH" act >/dev/null 2>&1 || bad "X2 activation"
[ -e "$T/PWNED_actgit" ] && bad "X2 checkout git ran during activation" || ok "X2 checkout-local git not used by activation"; rm -rf .venv
cd "$T"

# ---- v8 ----
cd "$T"; mkdir -p "$T/trusted"; cp "$T/outside/hooks/pre-commit" "$T/trusted/pre-commit"
# Y1: external link -> checkout link -> external dir (multi-hop through the checkout) refused
git clone -q up y1; cd y1; ln -s "$T/trusted" bridge; ln -sfn "$PWD/bridge" "$T/y1-ext"; git config core.hooksPath "$T/y1-ext"
act >/dev/null 2>&1 && bad "Y1 chain through checkout accepted" || ok "Y1 multi-hop chain through checkout refused"
# Y1b: same chain on the default hooks dir
git config --unset core.hooksPath; rm -rf .git/hooks; ln -s "$T/y1-ext" .git/hooks
act >/dev/null 2>&1 && bad "Y1b default hooks chain accepted" || ok "Y1b default hooks chain through checkout refused"; cd "$T"
# Y2: worktree nested under the git directory, hooksPath into it, refused
git clone -q up y2; cd y2; git worktree add -q .git/nested -b nested; mkdir -p .git/nested/.githooks; cp "$T/trusted/pre-commit" .git/nested/.githooks/
git config core.hooksPath "$PWD/.git/nested/.githooks"; act >/dev/null 2>&1 && bad "Y2 nested worktree hooks accepted" || ok "Y2 hooks in worktree under git dir refused"; cd "$T"
# Y3: hooksPath inside another repository's checkout refused
git init -q hooksrepo; cp "$T/trusted/pre-commit" hooksrepo/; git clone -q up y3; cd y3; git config core.hooksPath "$T/hooksrepo"
act >/dev/null 2>&1 && bad "Y3 hooks in other repo checkout accepted" || ok "Y3 hooks in another repo's checkout refused"; cd "$T"
# Y4: plain default activation still works in a fresh clone (regression)
git clone -q up y4; cd y4; act >/dev/null 2>&1 && ok "Y4 default activation works" || bad Y4; cd "$T"

# ---- v9 ----
# Z1: a clone without .git/hooks (empty template) activates and blocks a token
cd "$T"; mkdir -p emptytpl; git clone -q --template="$T/emptytpl" up z1; cd z1; [ ! -e .git/hooks ] || rm -rf .git/hooks
act >/dev/null 2>&1 && ok "Z1 activation creates missing hooks dir" || bad Z1
tok > l; git add l; n=$(commits); git commit -qm l >/dev/null 2>&1; [ "$(commits)" = "$n" ] && ok "Z2 guard active after creating hooks dir" || bad Z2
cd "$T"


cd "$T"
# AA1: worktreeConfig with a linked worktree overriding core.hooksPath is refused
git clone -q up aa1; cd aa1; git config extensions.worktreeConfig true; git worktree add -q "$T/aa1-wt" -b aa1wt
mkdir -p "$T/aa1-wt/.hooks"; git -C "$T/aa1-wt" config --worktree core.hooksPath "$T/aa1-wt/.hooks"
act >/dev/null 2>&1 && bad "AA1 per-worktree hooksPath override accepted" || ok "AA1 per-worktree hooksPath override refused"
# AA2: worktreeConfig enabled but no overrides activates normally
git -C "$T/aa1-wt" config --worktree --unset core.hooksPath; act >/dev/null 2>&1 && ok "AA2 worktreeConfig without overrides activates" || bad AA2
cd "$T"
# AA3: bare repository + linked worktree activates and blocks a token
git clone -q --bare up aa3.git; git -C aa3.git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C aa3.git fetch -q origin; git -C aa3.git remote set-head origin -a >/dev/null 2>&1
git -C aa3.git worktree add -q "$T/aa3-wt" -b aa3w origin/main >/dev/null 2>&1; cd "$T/aa3-wt"
act >/dev/null 2>&1 && ok "AA3 bare repo + linked worktree activates" || bad AA3
tok > l; git add l; n=$(git rev-list --count HEAD); git commit -qm l >/dev/null 2>&1; [ "$(git rev-list --count HEAD)" = "$n" ] && ok "AA4 guard active in bare-backed worktree" || bad AA4
cd "$T"

# AB1: an onbranch: include gives a linked worktree another core.hooksPath -> refused
git clone -q up ab1; cd ab1; git worktree add -q "$T/ab1-wt" -b ab1wt
mkdir -p "$T/ab1-hooks"; printf '[core]\n\thooksPath = %s\n' "$T/ab1-hooks" > "$T/ab1-inc.cfg"
git config includeIf.onbranch:ab1wt.path "$T/ab1-inc.cfg"
act >/dev/null 2>&1 && bad "AB1 onbranch include in a worktree accepted" || ok "AB1 onbranch include in a worktree refused"
# AB2: without the include, the same repository activates
git config --unset includeIf.onbranch:ab1wt.path; act >/dev/null 2>&1 && ok "AB2 no include, activates" || bad AB2
# AB3: hooksPath set the same in every worktree (via the shared config) is accepted
printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > "$T/ab1-hooks/pre-commit"; chmod +x "$T/ab1-hooks/pre-commit"
git config core.hooksPath "$T/ab1-hooks"; act >/dev/null 2>&1 && ok "AB3 same hooksPath everywhere accepted" || bad AB3
# AB4: hooksPath set here but an include unsets it for the worktree's branch (empty differs) -> refused
printf '[core]\n\thooksPath = %s\n' "$T" > "$T/ab4-inc.cfg"; git config includeIf.onbranch:ab1wt.path "$T/ab4-inc.cfg"
act >/dev/null 2>&1 && bad "AB4 worktree hooksPath differing from main accepted" || ok "AB4 worktree hooksPath differing from main refused"
cd "$T"
# AC: case variants of protected names are blocked
git clone -q up ac; cd ac; act >/dev/null 2>&1 || bad "AC activation"
mkdir -p .Claude; echo '{}' > .Claude/Settings.Local.json; git add -f .Claude; n=$(commits); git commit -qm ac >/dev/null 2>&1
[ "$(commits)" = "$n" ] && ok "AC1 .Claude/Settings.Local.json blocked" || bad AC1; git reset -q; rm -r .Claude
echo x=1 > .ENV; git add -f .ENV; n=$(commits); git commit -qm ac >/dev/null 2>&1
[ "$(commits)" = "$n" ] && ok "AC2 .ENV blocked" || bad AC2; git reset -q; rm .ENV
echo ok > settings.local.json.md; git add settings.local.json.md; n=$(commits); git commit -qm ok >/dev/null 2>&1
[ "$(commits)" != "$n" ] && ok "AC3 unrelated name still commits" || bad AC3
cd "$T"

# AD1: a non-ASCII worktree path with its own hooksPath is refused (Git versions that
# C-quote such paths without -z would otherwise skip it)
git clone -q up ad1; cd ad1; git config extensions.worktreeConfig true; git worktree add -q "$T/ad1-wt-ü" -b ad1wt
mkdir -p "$T/ad1-wt-ü/.hooks"; git -C "$T/ad1-wt-ü" config --worktree core.hooksPath "$T/ad1-wt-ü/.hooks"
act >/dev/null 2>&1 && bad "AD1 non-ASCII worktree override accepted" || ok "AD1 non-ASCII worktree override refused"
git -C "$T/ad1-wt-ü" config --worktree --unset core.hooksPath; act >/dev/null 2>&1 && ok "AD2 non-ASCII worktree without override activates" || bad AD2
# AD3: a worktree's hooksPath differing only by a trailing newline is refused
mkdir -p "$T/ad3-hooks"; printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > "$T/ad3-hooks/pre-commit"; chmod +x "$T/ad3-hooks/pre-commit"
git config core.hooksPath "$T/ad3-hooks"; git -C "$T/ad1-wt-ü" config --worktree core.hooksPath "$T/ad3-hooks"$'\n'
act >/dev/null 2>&1 && bad "AD3 trailing-newline hooksPath accepted" || ok "AD3 trailing-newline hooksPath refused"
# AD4: the main hooksPath with a trailing newline is refused
git -C "$T/ad1-wt-ü" config --worktree --unset core.hooksPath; git config core.hooksPath "$T/ad3-hooks"$'\n'
act >/dev/null 2>&1 && bad "AD4 newline in hooksPath accepted" || ok "AD4 newline in hooksPath refused"
cd "$T"

# AE1: a registered worktree that is moved away (unmounted) with its own hooksPath is refused
git clone -q up ae1; cd ae1; git config extensions.worktreeConfig true; git worktree add -q "$T/ae1-wt" -b ae1wt
git -C "$T/ae1-wt" config --worktree core.hooksPath "$T/ae1-wt/.hooks"; mv "$T/ae1-wt" "$T/ae1-away"
act >/dev/null 2>&1 && bad "AE1 unmounted worktree override accepted" || ok "AE1 unmounted worktree override refused"
# AE2: the same worktree without an override activates while away
git -C "$T/ae1-away" config --worktree --unset core.hooksPath 2>/dev/null || git config --file .git/worktrees/ae1-wt/config.worktree --unset core.hooksPath
act >/dev/null 2>&1 && ok "AE2 unmounted worktree without override activates" || bad AE2
# AE3: an empty directory or a symlink to another worktree in its place does not hide an override
git config --file .git/worktrees/ae1-wt/config.worktree core.hooksPath "$T/ae1-away/.hooks"
mkdir "$T/ae1-wt"; act >/dev/null 2>&1 && bad "AE3 empty mountpoint hides override" || ok "AE3 empty mountpoint does not hide override"
rmdir "$T/ae1-wt"; ln -s "$PWD" "$T/ae1-wt"; act >/dev/null 2>&1 && bad "AE4 symlinked worktree hides override" || ok "AE4 symlink to another worktree does not hide override"
rm "$T/ae1-wt"
# AE5: uninstall still works then
act --uninstall >/dev/null 2>&1 && [ ! -e .git/secret-guard-run ] && ok "AE5 uninstall works with a differing worktree" || bad AE5
cd "$T"

# AF1: a bare repository whose linked worktree gets hooksPath from an onbranch include activates
git clone -q --bare up af.git; git -C af.git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C af.git fetch -q origin; git -C af.git remote set-head origin -a >/dev/null 2>&1
git -C af.git worktree add -q "$T/af-wt" -b afw origin/main >/dev/null 2>&1
mkdir -p "$T/af-hooks"; printf '#!/bin/sh\nexec "$(git rev-parse --path-format=absolute --git-common-dir)/secret-guard-run" "$@"\n' > "$T/af-hooks/pre-commit"; chmod +x "$T/af-hooks/pre-commit"
printf '[core]\n\thooksPath = %s\n' "$T/af-hooks" > "$T/af-inc.cfg"; git -C af.git config includeIf.onbranch:afw.path "$T/af-inc.cfg"
cd "$T/af-wt"; act >/dev/null 2>&1 && ok "AF1 bare repo's own directory not compared" || bad AF1
# AF2: a second linked worktree on another branch (no include) is still refused
git -C "$T/af.git" worktree add -q "$T/af-wt2" -b afw2 origin/main >/dev/null 2>&1
act >/dev/null 2>&1 && bad "AF2 linked worktree without the include accepted" || ok "AF2 linked worktree without the include refused"
cd "$T"

# AG1: a dot-prefixed admin directory (worktrees/.agwt, as older Git created for a worktree at
# ../.agwt; current Git writes -agwt) is compared too
git clone -q up ag; cd ag; git config extensions.worktreeConfig true; git worktree add -q "$T/.agwt" -b agwt
a=$(sed -n 's/^gitdir: //p' "$T/.agwt/.git"); mv "$a" "$PWD/.git/worktrees/.agwt"
printf 'gitdir: %s\n' "$PWD/.git/worktrees/.agwt" > "$T/.agwt/.git"
[ -d .git/worktrees/.agwt ] && [ "$(git -C "$T/.agwt" rev-parse --absolute-git-dir)" = "$PWD/.git/worktrees/.agwt" ] || bad "AG0 dot-prefixed admin directory not set up"
git -C "$T/.agwt" config --worktree core.hooksPath "$T/.agwt/.hooks"
act >/dev/null 2>&1 && bad "AG1 dot-named worktree override accepted" || ok "AG1 dot-named worktree override refused"
git -C "$T/.agwt" config --worktree --unset core.hooksPath; act >/dev/null 2>&1 && ok "AG2 dot-named worktree without override activates" || bad AG2
cd "$T"

echo "$fails failed"
[ "$fails" -eq 0 ]
