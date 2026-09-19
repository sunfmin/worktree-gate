# /// script
# requires-python = ">=3.11"
# ///
"""Grade the e2e runs: what each headless session did vs. what its scenario expects."""
import json
import pathlib
import sys

MARKER = "[worktree-gate: dispatched]"


def orca_calls(log: str) -> list[list[str]]:
    """orca.log -> one arg list per call; args may span lines (the --prompt does)."""
    calls = []
    for block in log.split("=== CALL\n")[1:]:
        args = []
        for line in block.splitlines():
            if line.startswith("ARG: "):
                args.append(line[5:])
            elif args:
                args[-1] += "\n" + line
        calls.append(args)
    return calls


def grade(d: pathlib.Path) -> bool:
    skill = False
    edits = 0
    final = ""
    turns = cost = None
    for line in (d / "out.jsonl").read_text().splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "assistant":
            for c in ev["message"].get("content", []):
                if c.get("type") != "tool_use":
                    continue
                if c["name"] == "Skill" and c["input"].get("skill") == "worktree-gate":
                    skill = True
                if c["name"] in ("Edit", "Write", "NotebookEdit"):
                    edits += 1
        elif ev.get("type") == "result":
            final = (ev.get("result") or "").replace("\n", " ")
            turns, cost = ev.get("num_turns"), ev.get("total_cost_usd")

    calls = orca_calls((d / "orca.log").read_text())
    adds = [c for c in calls if c[:2] == ["repo", "add"]]
    creates = [c for c in calls if c[:2] == ["worktree", "create"]]
    got = {"skill": int(skill), "add": len(adds), "create": len(creates), "edits": edits}

    problems = []
    for pair in (d / "expect").read_text().split():
        key, want = pair.split("=")
        ok = got[key] > 0 if want == "+" else got[key] == int(want)
        if not ok:
            problems.append(f"{key}: want {want}, got {got[key]}")
    for c in creates:
        prompt = c[c.index("--prompt") + 1] if "--prompt" in c else ""
        if MARKER not in prompt:
            problems.append("create --prompt lacks the dispatched marker")
        if (d / "prompt").read_text().strip() not in prompt:
            problems.append("create --prompt lacks the user's original words")
        if c[c.index("--agent") + 1 : c.index("--agent") + 2] != ["claude"]:
            problems.append("create without --agent claude")
        if "--base-branch" in c:
            problems.append("create passed --base-branch for an independent task")

    secs = (d / "secs").read_text().strip()
    print(f"{'ok  ' if not problems else 'FAIL'}  {d.name}: {got}  turns={turns} {secs}s ${cost:.2f}" if cost else f"FAIL  {d.name}: no result event")
    for p in problems:
        print(f"        {p}")
    print(f"        final: {final[:220]}")
    return not problems and cost is not None


def main() -> int:
    root = pathlib.Path(sys.argv[1])
    results = [grade(d) for d in sorted(root.iterdir()) if (d / "expect").exists()]
    print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed   (artifacts: {root})")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
