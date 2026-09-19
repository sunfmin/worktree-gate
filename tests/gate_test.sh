#!/usr/bin/env bash
# Unit tests for gate.sh: every verdict path, against a fake orca. Fast, no tokens.
#   bash tests/gate_test.sh
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0

# check <name> <output> <expected substring>...
check() {
    local name=$1 out=$2 ok=1 want
    shift 2
    for want in "$@"; do
        [[ $out == *"$want"* ]] || { ok=0; printf '    missing: %s\n' "$want"; }
    done
    if [[ $ok == 1 ]]; then
        pass=$((pass + 1)); printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n%s\n' "$name" "$(printf '%s\n' "$out" | sed 's/^/    | /')"
    fi
}

gate() { # <fixture dir> [subdir] -> gate output, fake orca first on PATH
    # Fixtures live under a temp dir, which the gate refuses to register by default.
    (cd "$1/${2:-repo}" && PATH="$1/bin:$PATH" GATE_ALLOW_TMP=1 bash "$GATE" 2>&1)
}

calls() { # <fixture dir> -> orca.log flattened to one line per call
    tr '\n' ' ' < "$1/orca.log" | sed 's/=== CALL/\n/g'
}

mkdir -p "$T/nogit"
check "non-git dir -> STAY" "$(cd "$T/nogit" && bash "$GATE" 2>&1)" \
    "verdict: STAY" "not a git repo"

mkrepo "$T/noorca"
check "orca not installed -> STAY" "$(cd "$T/noorca/repo" && PATH=/usr/bin:/bin bash "$GATE" 2>&1)" \
    "verdict: STAY" "orca CLI not installed"

# --- a repo Orca doesn't know yet gets registered, then gated like any other

mkshim "$T/unmanaged" unmanaged; mkrepo "$T/unmanaged"
root=$(cd "$T/unmanaged/repo" && pwd -P)
check "unknown repo -> registered, then DISPATCH" "$(gate "$T/unmanaged")" \
    "verdict: DISPATCH" "orca: newly registered $root"
check "  ...via orca repo add --path <repo root>" "$(calls "$T/unmanaged")" \
    "ARG: repo ARG: add ARG: --path ARG: $root "

mkshim "$T/linked" unmanaged; mkrepo "$T/linked"
root=$(cd "$T/linked/repo" && pwd -P)
(cd "$T/linked/repo" && git worktree add -q -b side-task ../linked-wt)
check "unknown repo, run from a linked git worktree -> JUDGE" "$(gate "$T/linked" linked-wt)" \
    "verdict: JUDGE" "branch: side-task"
check "  ...registers the main checkout, not the linked worktree" "$(calls "$T/linked")" \
    "ARG: --path ARG: $root "

mkshim "$T/tmpguard" unmanaged; mkrepo "$T/tmpguard"
check "unknown repo under a temp dir -> STAY, not registered" \
    "$(cd "$T/tmpguard/repo" && PATH="$T/tmpguard/bin:$PATH" bash "$GATE" 2>&1)" \
    "verdict: STAY" "temp checkout"
[[ $(calls "$T/tmpguard") != *"ARG: add"* ]]
check "  ...and orca repo add was never called" "$?" "0"

mkshim "$T/addfails" add-fails; mkrepo "$T/addfails"
check "orca repo add rejected -> STAY with the error" "$(gate "$T/addfails")" \
    "verdict: STAY" "orca repo add failed" "not a project"

mkshim "$T/down" down; mkrepo "$T/down"
check "Orca not running -> STAY, nothing registered" "$(gate "$T/down")" \
    "verdict: STAY" "not reachable" "Orca is not running"
[[ $(calls "$T/down") != *"ARG: add"* ]]
check "  ...and orca repo add was never called" "$?" "0"

# --- Orca-managed checkouts

mkshim "$T/hang" hang; mkrepo "$T/hang"
check "orca hangs -> STAY after timeout" "$(GATE_ORCA_TIMEOUT=1 gate "$T/hang")" \
    "verdict: STAY" "did not answer"

mkshim "$T/main" managed; mkrepo "$T/main"
check "managed, default branch, clean -> DISPATCH" "$(gate "$T/main")" \
    "verdict: DISPATCH" "branch: main (default: main)" "dirty: 0 files"

echo wip > "$T/main/repo/scratch.txt"
check "managed, default branch, dirty -> DISPATCH + note" "$(gate "$T/main")" \
    "verdict: DISPATCH" "dirty: 1 files" "?? scratch.txt" "uncommitted changes stay"

mkshim "$T/feature" managed; mkrepo "$T/feature" feature
check "managed, feature branch -> JUDGE with branch facts" "$(gate "$T/feature")" \
    "verdict: JUDGE" "branch: add-name-flag (default: main)" "pr: " "add --name flag to greet"

(cd "$T/feature/repo" && git checkout -q --detach)
check "managed, detached HEAD -> JUDGE" "$(gate "$T/feature")" \
    "verdict: JUDGE" "detached HEAD"

# Default branch is read from origin/HEAD, never assumed to be main.
mkshim "$T/trunk" managed
git init -q --bare -b trunk "$T/trunk/remote.git"
mkrepo "$T/trunk/seed"
(cd "$T/trunk/seed/repo" && git branch -m main trunk && git push -q "$T/trunk/remote.git" trunk)
git clone -q "$T/trunk/remote.git" "$T/trunk/repo"
check "default branch named trunk -> DISPATCH" "$(gate "$T/trunk")" \
    "verdict: DISPATCH" "branch: trunk (default: trunk)"
(cd "$T/trunk/repo" && git checkout -q -b some-feature)
check "feature off trunk -> JUDGE" "$(gate "$T/trunk")" \
    "verdict: JUDGE" "branch: some-feature (default: trunk)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
