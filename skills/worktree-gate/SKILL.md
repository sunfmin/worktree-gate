---
name: worktree-gate
description: Gate to pass before the first edit of any code-change task in a git repo (feature, fix, refactor) - decides whether the work stays in this checkout or is dispatched to a new Orca worktree with its own agent. Also use when the user asks to move a task into a new worktree.
---

# worktree-gate

改代码的任务，第一次 Edit / 开分支**之前**过一次 gate。一个任务过一次。

任务 prompt 里带 `[worktree-gate: dispatched]` -> 你就是被派来的那个 agent，gate 已经过了，直接就地做。

## 1. 跑 gate

```
bash ~/.claude/skills/worktree-gate/scripts/gate.sh
```

输出一个 verdict 加支撑它的事实（当前分支 / 默认分支、PR、脏文件、这条分支上的提交）。

Orca 还不认识的 repo，gate 会顺手注册进去（输出里有 `orca: newly registered <path>`）-> 回我话的时候带一句。

## 2. 按 verdict 走

- **STAY** -> Orca 接不了这个 checkout（没装 / 没开 / 临时目录，reason 里写了）。就地做；在主干上就先开分支（CLAUDE.md 的 auto commit & push 那条）。
- **DISPATCH** -> 派出去（第 3 步）。
- **JUDGE** -> 你在一条 feature 分支上。拿 gate 给的分支名 / PR / 提交，对照新任务：
  - 是这条分支那件事的延续（修它、续它、补测试、改它的文档）-> 就地做。
  - 是另一件事 -> 派出去。
  - 拿不准 -> 问我一句。

## 3. 派出去

```
orca worktree create --name <任务名> --agent claude --no-parent --json --prompt "$(cat <<'EOF'
<我的原话，原样>

<这边对话里已经定下、新 agent 看不到的东西：结论、文件路径、约束。没有就省掉>

[worktree-gate: dispatched]
EOF
)"
```

- `--name`：用任务本身起名（`fix-login-redirect`）。
- base：省掉 `--base-branch`，Orca 自己取 repo 的默认分支。我明说「从当前分支切」/ stacked -> 才传 `--base-branch <当前分支>`。
- lineage：新任务跟当前 worktree 的活儿相关 -> 把 `--no-parent` 换成 `--parent-worktree active`。
- worktree 一律用 `orca worktree create` 建：Orca 只给它建的 worktree 出卡片，`EnterWorktree` 建在 `.claude/worktrees/` 的那种在 Orca 里看不见。

完成标志：create 返回 `"ok": true`。回我一行 —— worktree 名 + 路径 + 分支 + base —— 然后**这边收工**：这件事从此归新 agent，这边的 checkout 保持原样。

gate 输出里有 `claude trust: NOT accepted` -> 照样派，但回我的那一行里说清：新 agent 会停在 trust 提示上，等我去点。

create 失败 -> 把错误原样给我，停下等我定。
