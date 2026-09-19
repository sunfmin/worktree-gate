# worktree-gate

Claude Code skill：改代码的任务动手之前过一道 gate，决定**就地做**，还是**派到新的 [Orca](https://github.com/stablyai/orca) worktree** 交给一个新 agent。

```
npx skills add sunfmin/worktree-gate -g
```

## 它怎么判

`scripts/gate.sh` 收集事实、给出 verdict，agent 按 verdict 走：

| 状态 | verdict | 结果 |
| --- | --- | --- |
| 没装 orca / Orca 没开 / 临时目录 | `STAY` | 就地做（在主干上先开分支） |
| Orca 还不认识这个 repo | — | 先 `orca repo add` 注册，再按下面两行判 |
| 在默认分支上 | `DISPATCH` | `orca worktree create --agent claude --prompt ...`，这边收工 |
| 在 feature 分支上 | `JUDGE` | 同一件事 -> 就地做；另一件事 -> 派出去 |

默认分支从 `origin/HEAD` 现取；新 worktree 的 base 交给 Orca 取 repo 默认值。

## 让它稳定触发

skill 的 description 常驻上下文，但光靠它不够稳。在全局 `CLAUDE.md` 里留一行指针：

```markdown
## 改代码前 -> 先过 worktree-gate

要动 git repo 里的代码（feature / fix / refactor）-> **第一次 Edit / 开分支之前**，先加载 `worktree-gate` skill，按它的 verdict 走。

问答 / 调研 / 只读 / 改我的配置 -> 直接就地做，不过 gate。
```

## 测试

```
bash tests/gate_test.sh   # gate.sh 的每条 verdict 路径，假 orca，~5s，不花 token
bash tests/e2e.sh         # 真的无头 claude -p 会不会触发 gate 并照 verdict 做，~2min，~$3
```

两套都用 `tests/fake-orca` 顶在 PATH 最前面，碰不到真的 Orca。`e2e.sh` 测的是**装好的** skill（`~/.claude/skills/worktree-gate`）加你的全局 `CLAUDE.md`。
