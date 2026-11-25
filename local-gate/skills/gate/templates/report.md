结论：<pass / needs_fix / needs_decision / verify_failed>（<通过 / 待修复 / 需裁决 / 验证未通过>）—— <一句话说明>

- 模式：<full / recheck / verify_only>；档位：<T0–T3>（<判档理由>）
- 范围：<BASE 短号>..<TARGET 短号>，<COMMITS> 个提交，<FILES> 个文件，<LINES> 行
- 意图：<一句话>
- 模型调用：审查 <n>，安全审查 <n>，复核 <n>，复查 <n>；独立性：<正常 / 降级>

## 需要修的问题（CONFIRMED）

1. [Important] 文件:行 — 问题 — 触发条件 — 证据 — 建议修法（升级自 Nit / Pre-existing 时注明）

## 待你判断（UNSURE）

- 文件:行 — 问题 — 缺什么信息

## Nit（不阻塞，最多 3 条）

- 文件:行 — 问题

## Pre-existing（不阻塞，已记入 backlog）

- 文件:行 — 问题

## 建议人工查看（最多 3 处）

- 文件:行范围 — 原因

## 验证证据

### <命令>

```text
<原始输出；太长就保留开头和结尾>
```

## 修复

<fix_mode 为 apply 时：工作区里改了哪些文件、各自修的是哪条问题、补了哪些测试；否则：修复交接单>

## 建议的提交说明

<按公司规范；T2/T3 写风险，T3 写回滚办法>

## 附录：已驳回（REFUTED）

- 文件:行 — 原问题 — 反证
