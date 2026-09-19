#!/usr/bin/env bash
# End-to-end trigger test: does a real headless `claude -p` session reach the gate
# and act on its verdict? Tests the INSTALLED skill (~/.claude/skills/worktree-gate)
# together with your global CLAUDE.md, in scratch repos, with a fake orca first on
# PATH - the real Orca is never touched. Slow (~1-2 min) and costs tokens (~$2-3).
#   bash tests/e2e.sh [out-dir]
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -e "$HOME/.claude/skills/worktree-gate/SKILL.md" ] || { echo "skill not installed in ~/.claude/skills" >&2; exit 2; }
ROOT=${1:-$(mktemp -d)}
rm -rf "$ROOT"; mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd -P)

run() { # <id> <orca mode> <feature|main> <expectations> <prompt>
    local d="$ROOT/$1"
    mkshim "$d" "$2"
    mkrepo "$d" "$3"
    echo "$4" > "$d/expect"
    echo "$5" > "$d/prompt"
    local t0; t0=$(date +%s)
    # ORCA_* unset so nothing can resolve back to the real Orca session we run inside.
    ( cd "$d/repo" && env -u ORCA_WORKTREE_ID -u ORCA_TAB_ID PATH="$d/bin:$PATH" GATE_ALLOW_TMP=1 \
        claude -p --dangerously-skip-permissions --max-turns 25 --output-format stream-json --verbose "$5" \
        > "$d/out.jsonl" 2> "$d/err.txt" )
    echo "$(( $(date +%s) - t0 ))" > "$d/secs"
}

NEW_TASK="给 greet.py 加一个 --name 参数，不传的时候还是打印 hello"

# expectations: skill/add/create are exact counts-as-booleans; edits is 0 or + (at least one)
run a-main-newtask      managed   main    "skill=1 add=0 create=1 edits=0" "$NEW_TASK" &
run b-feature-sametask  managed   feature "skill=1 add=0 create=0 edits=+" "给 --name 参数补一个测试" &
run c-feature-othertask managed   feature "skill=1 add=0 create=1 edits=0" "另一件不相关的事：加一个 farewell.py，打印 goodbye，也带 --name 参数" &
run d-unknown-repo      unmanaged main    "skill=1 add=1 create=1 edits=0" "$NEW_TASK" &
run e-orca-down         down      main    "skill=1 add=0 create=0 edits=+" "$NEW_TASK" &
run f-question          managed   main    "skill=0 add=0 create=0 edits=0" "greet.py 现在接受哪些命令行参数？" &
wait

uv run --quiet "$TESTS_DIR/e2e_report.py" "$ROOT"
