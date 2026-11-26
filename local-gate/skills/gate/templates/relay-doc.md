# 接力文档格式

接力目录里每个角色一份文档：`reviewer.md`、`security-reviewer.md`、`refuter.md`。

- 文件头只写下面三项。范围、角色、依据的文档和封存时间由 `relay-seal` 补上，你写了也会被覆盖。
- 结果部分照抄角色最后一条消息的完整原文，不要改写、删减或加评论。
- 写完运行 `relay-seal <目录> <角色>`。它报错时按提示改好再封存。

| 文件头 | 写什么 |
|---|---|
| `harness` | 执行这个角色的工具：Claude Code、Codex、Kimi Code、ZCode、DeepSeek Harness 或其他 |
| `model` | 模型名；不知道就写 `unknown` |
| `independence` | `normal` 或 `degraded`，见 SKILL.md 的"独立性" |

## 审查员、安全审查员

```markdown
---
harness: Codex
model: unknown
independence: normal
---

# 审查员结果

<审查员最后一条消息的完整原文：从"候选："那一行开始；复查任务从"复查："那一行开始>
```

安全审查员把标题换成"安全审查员结果"。

## 复核员

```markdown
---
harness: Claude Code
model: unknown
independence: normal
---

# 复核员结果

## 交给复核员的候选

<预检之后实际交给复核员的全部候选，原样列出。每条注明来自 reviewer.md 还是 security-reviewer.md；预检升级的注明"预检升级自 Pre-existing">

## 复核结论

<复核员最后一条消息的完整原文，从"复核："那一行开始>
```
