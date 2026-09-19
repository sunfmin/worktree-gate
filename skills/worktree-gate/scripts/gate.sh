#!/usr/bin/env bash
# worktree-gate: facts + verdict for "do this code task here, or dispatch it to
# a new Orca worktree?". Its one side effect: a repo Orca doesn't know yet gets
# registered (`orca repo add`), so the gate applies everywhere Orca runs. Verdicts:
#   STAY     - Orca can't take this checkout (not installed, not answering,
#              temp dir, registration failed); work here.
#   DISPATCH - on the default branch of an Orca-managed checkout; hand off.
#   JUDGE    - on a feature branch; the agent decides from the facts below.
set -u

ORCA_TIMEOUT=${GATE_ORCA_TIMEOUT:-5}
GH_TIMEOUT=${GATE_GH_TIMEOUT:-6}

# macOS has no timeout(1); perl ships with the OS. Exit 124 on timeout, like GNU
# timeout. The whole process group is killed so a hung grandchild can't keep the
# output pipe open and stall the caller.
with_timeout() {
    perl -e '
        use Time::HiRes qw(alarm); # core alarm() can fire up to 1s early
        my $secs = shift;
        my $pid = fork();
        if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
        $SIG{ALRM} = sub { kill "TERM", -$pid; exit 124; };
        alarm $secs;
        waitpid($pid, 0);
        exit($? >> 8);
    ' "$@"
}

verdict() {
    printf 'verdict: %s\nreason: %s\n' "$1" "$2"
    [[ -n ${registered:-} ]] && printf 'orca: newly registered %s\n' "$registered"
    return 0
}

is_ok() { # <orca --json output>
    [[ ${1//[[:space:]]/} == *'"ok":true'* ]]
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    verdict STAY "not a git repo"
    exit 0
fi

if ! command -v orca >/dev/null 2>&1; then
    verdict STAY "orca CLI not installed"
    exit 0
fi

# `worktree current` is the precise check: a reachable Orca runtime is not enough,
# the checkout itself must be one Orca manages.
current=$(with_timeout "$ORCA_TIMEOUT" orca worktree current --json 2>&1)
if [[ $? == 124 ]]; then
    verdict STAY "orca did not answer within ${ORCA_TIMEOUT}s"
    exit 0
fi
registered=""
if ! is_ok "$current"; then
    # Only an explicit "no managed worktree here" means Orca is up and simply
    # doesn't know the repo. Anything else (app not running, ...) -> work here.
    if [[ ${current//[[:space:]]/} != *'"code":"selector_not_found"'* ]]; then
        verdict STAY "Orca is not reachable: $(printf '%s' "$current" | tr -s '[:space:]' ' ' | cut -c1-200)"
        exit 0
    fi

    # Register the main checkout, not a linked worktree of it.
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    if [[ $(basename "$common") == .git ]]; then
        root=$(dirname "$common")
    else
        root=$(git rev-parse --show-toplevel)
    fi

    # `orca repo` has no remove, so throwaway clones stay out of Orca.
    if [[ -z ${GATE_ALLOW_TMP:-} ]]; then
        case "$root/" in
            /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*)
                verdict STAY "temp checkout ($root) - not registering it with Orca"
                exit 0
                ;;
        esac
    fi

    added=$(with_timeout "$ORCA_TIMEOUT" orca repo add --path "$root" --json 2>&1)
    if ! is_ok "$added"; then
        verdict STAY "orca repo add failed for $root: $(printf '%s' "$added" | tr -s '[:space:]' ' ' | cut -c1-200)"
        exit 0
    fi
    registered=$root

    current=$(with_timeout "$ORCA_TIMEOUT" orca worktree current --json 2>&1)
    if ! is_ok "$current"; then
        verdict STAY "registered $root with Orca, but it still doesn't manage this checkout ($(pwd))"
        exit 0
    fi
fi

branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
default=${default#origin/}
if [[ -z $default ]]; then
    # No origin/HEAD (never cloned, or remote-less): fall back to the usual names.
    for name in main master; do
        if git show-ref --verify --quiet "refs/heads/$name"; then
            default=$name
            break
        fi
    done
fi

dirty=$(git status --porcelain 2>/dev/null)
dirty_count=0
[[ -n $dirty ]] && dirty_count=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')

print_dirty() {
    printf 'dirty: %s files\n' "$dirty_count"
    if [[ $dirty_count -gt 0 ]]; then
        printf '%s\n' "$dirty" | head -10 | sed 's/^/  /'
        [[ $dirty_count -gt 10 ]] && printf '  ... %s more\n' "$((dirty_count - 10))"
    fi
}

if [[ -n $branch && $branch == "$default" ]]; then
    verdict DISPATCH "on default branch '$default' of an Orca-managed checkout - nothing here to continue"
    printf 'branch: %s (default: %s)\n' "$branch" "$default"
    print_dirty
    [[ $dirty_count -gt 0 ]] && printf 'note: uncommitted changes stay in this checkout; the new worktree starts clean\n'
    exit 0
fi

verdict JUDGE "on '${branch:-detached HEAD}', not the default branch - same task stays, a different task dispatches"
printf 'branch: %s (default: %s)\n' "${branch:-detached HEAD}" "${default:-unknown}"

pr="unknown (gh unavailable)"
if command -v gh >/dev/null 2>&1 && [[ -n $branch ]]; then
    pr=$(with_timeout "$GH_TIMEOUT" gh pr view --json number,state,title,url \
        -q '"#\(.number) \(.state) \(.title) \(.url)"' 2>/dev/null) || pr="none"
    [[ -z $pr ]] && pr="none"
fi
printf 'pr: %s\n' "$pr"

print_dirty

if [[ -n $default ]]; then
    base="origin/$default"
    git rev-parse --verify --quiet "$base" >/dev/null || base=$default
    printf 'commits on this branch (vs %s):\n' "$base"
    commits=$(git log --oneline -8 "$base..HEAD" 2>/dev/null)
    if [[ -n $commits ]]; then
        printf '%s\n' "$commits" | sed 's/^/  /'
    else
        printf '  (none yet)\n'
    fi
fi
