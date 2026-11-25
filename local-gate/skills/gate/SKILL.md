---
name: gate
description: "本地提交之后的评审关卡，只在用户手动运行时使用，不要自动调用。只读 git：定范围、判档、验证、单轮审查与复核，给出修复建议和报告；提交和推送留给用户。参数可以是 status、某个提交或 A..B 范围，后面可以跟一句改动意图。"
disable-model-invocation: true
argument-hint: "[status | <提交> | <A..B>] [改动意图]"
---

# /gate：本地评审关卡

- 本 skill 目录：`{{SKILL_DIR}}`
- 辅助脚本：`"{{SH}}" "{{SKILL_DIR}}/scripts/gate-helper.sh" <子命令>`。在 PowerShell 里要在前面加 `&`。脚本只读 git，输出 `KEY=VALUE` 行。
- 如果上面显示的还是 `{{SKILL_DIR}}` 这样的占位符（没有用安装脚本），就把它换成本 SKILL.md 所在的目录，`{{SH}}` 换成 `sh`。

## 铁律

1. 全程只用只读 git 命令：diff、show、log、blame、rev-parse、rev-list、merge-base、patch-id、archive、status。不做 commit、push、pull、fetch、merge、rebase、reset、checkout、switch、stash、tag、add、restore、cherry-pick、revert，也不创建、删除或改名分支。需要这些操作才能继续时，停下来告诉用户。
2. 启动每个子代理时，都把第 1 条写进它的任务说明。
3. 不调用其他 skill；需要独立审查时只启动子代理。
4. 只在用户明确运行本 skill 时执行。
5. 模型调用不超过上限：T0 为 0；T1 为审查 1 + 复核最多 1；T2 再加复查最多 1；T3 为审查和安全审查并行 2 + 复核最多 1 + 复查最多 1。

## 参数

- 不带参数：审查默认范围（上次通过之后的本地提交）。
- `status`：只看状态，见"status 模式"。
- 提交号，或 `分支~n` 之类：只审这一个提交。
- `A..B`：审这个范围。
- 其余文字是这次改动的意图。没有意图就先问用户要一句话。

## 步骤

### 1. 定范围

运行 `range`（指定了提交或范围就加在后面），按 `MODE` 处理：

| MODE | 含义 | 做法 |
|---|---|---|
| `full` | 完整审查 | 继续第 2 步 |
| `recheck` | 上次结论是"待修复"，修复已经提交 | 按"复查模式"处理 |
| `recheck_pending` | 上次结论是"待修复"，但修复还没提交 | 告诉用户先提交修复，结束 |
| `verify_only` | 同步远端后提交号变了，但内容都审过 | 只跑第 3 步验证；通过就运行 `mark-pass PASS_FROM TARGET`，结束 |
| `already_passed` | 最新提交已经通过 | 告诉用户，结束 |

同时记下 `BASE`、`TARGET`、`PASS_FROM`、`COMMITS`、`FILES`、`LINES`、`READ_FROM`、`STATE_DIR`、`PROFILE`、`PROFILE_EXISTS`。

- 审查范围就是 `git diff BASE TARGET`。`READ_FROM=worktree` 时直接读工作区文件，否则用 `git show TARGET:<路径>`。
- `PROFILE_EXISTS=no`：运行 `profile-init` 生成项目规则，和用户一起把 `checks` 改成这个项目真实的命令后再继续。
- `LINES` 扣掉 `skip_paths` 和生成文件后，仍然超过 `split_over_lines` 时：`COMMITS` 大于 1 就按提交分段审（每段是 `<提交>^ <提交>`）；单个提交就超过的，提醒用户拆分。用户坚持就继续，并把人工档位提一级。

### 2. 判档

按项目规则的 `tiers` 判档：命中 T3 路径就是 T3；命中 T2 路径至少是 T2；所有文件都匹配 `T0_only_if_all_match` 才是 T0；其余是 T1。你可以因为语义风险升档（例如改了所有用户都会走到的默认值），要写明理由；不能降档。

### 3. 验证

- `READ_FROM=worktree` 就在仓库根目录跑。否则先运行 `export TARGET <临时目录>` 导出代码，在那里跑（需要先装依赖）。
- 按档位执行 `checks`：T0 跑 `fast`；T1 跑 `fast`、`build`、`test_related`（`{files}` 换成改动的文件）；T2/T3 跑 `fast`、`build`、`test_full`。T2/T3 的行为变更还要实际运行或复现一次，T3 再加失败路径。
- 每条命令和原始输出都写进报告，不要转述；输出太长就保留开头和结尾。
- 有命令失败：结论是 `verify_failed`，跳到第 8 步写报告，然后结束。

### 4. 审查（T0 跳过）

按"启动独立角色"启动审查员 `gate-reviewer`。T3，或者改动涉及输入处理、权限、密钥、依赖时，同时启动安全审查员 `gate-security-reviewer`，两个并行。只传给它们这些内容：

- 铁律第 1 条；
- `BASE` 和 `TARGET`，让它自己运行 `git diff BASE TARGET`；
- 读代码的方式（工作区，或 `git show TARGET:<路径>`）；
- 改动意图；
- 项目规则文件的路径。

不要把你自己的推理，也不要把写代码时的对话传给它们。

### 5. 规则预检

把审查员和安全审查员报的每条 Pre-existing 的位置交给 `in-changed BASE TARGET <文件:行> ...`。结果是 `changed` 的，改成 Important 候选。

### 6. 复核

把全部候选（Important、Nit、Pre-existing，包括安全审查员报的）一次交给复核员 `gate-refuter`；一条候选都没有就跳过。复核员会核对级别，把标低的升为 Important，并对每条 Important 给出 CONFIRMED / REFUTED / UNSURE。

### 7. 修复

- 同时满足下面三条时，把 CONFIRMED 问题的修复写进工作区：项目规则里 `fix_mode: apply`；`TARGET` 就是 `HEAD`；`READ_FROM=worktree`。能补回归测试就补上，然后重跑第 3 步的验证。不暂存、不提交。
- 不满足时，只按 `{{SKILL_DIR}}/templates/handoff.md` 写修复交接单。
- 你认为某条 CONFIRMED 不成立时，不要自己驳回：写明反证，交给用户决定。

### 8. 报告与记录

- 运行 `report-path <档位>` 拿到报告路径和其他记录文件的路径，按 `{{SKILL_DIR}}/templates/report.md` 写报告，首行是结论。
- 结论只有四种：`pass`（没有 CONFIRMED，也没有 UNSURE）、`needs_fix`（有 CONFIRMED）、`needs_decision`（只剩 UNSURE，或需要用户裁决）、`verify_failed`。
- 覆盖写 `LAST_JSON`，每个键单独一行：

  ```json
  {
    "result": "needs_fix",
    "mode": "full",
    "tier": "T2",
    "base": "<BASE>",
    "target": "<TARGET>",
    "report": "<报告路径>",
    "time": "<NOW>"
  }
  ```

- 结论是 `pass` 时运行 `mark-pass PASS_FROM TARGET`。
- 没有升级的 Pre-existing 追加到 `BACKLOG`。
- 在 `LOG` 里追加一行 JSON，字段：`time`、`tier`、`mode`、`result`、`llm_calls`、`important`、`upgraded`、`refuted`、`unsure`、`fixed`、`dismissed`。

### 9. 人工确认

按档位请用户确认（T0 跳过）：T1 读报告；T2 看审查员建议的最多 3 处；T3 关键部分逐行读，并确认回滚办法。

- 用户对 UNSURE 或有异议的问题做出裁决后，按裁决更新报告、`last.json` 和结论；改成 `pass` 时运行 `mark-pass PASS_FROM TARGET`。
- 用户驳回某条发现时，问要不要把它写进项目规则的 `do_not_report`。
- 最后提醒用户：提交由他自己或新会话完成；修复提交后再运行一次本 skill 复查。

## 复查模式（MODE=recheck）

- 范围是"上次审查的版本 → HEAD"，也就是修复带来的差异。
- 照跑第 3 步验证。
- 从 `last.json` 指向的报告里取出上次的问题列表。
- T2/T3 且修复差异较大（超过几十行，或者动了问题位置以外的地方）时，以复查模式启动一次 `gate-reviewer`，只传上次的问题列表和修复差异；其他情况把修复差异直接给用户看。
- 仍有问题：结论 `needs_decision`，不再加审查轮次。没有问题：结论 `pass`，运行 `mark-pass PASS_FROM TARGET`。

## status 模式

运行 `status`，用中文简要告诉用户：上次结论（`LAST_RESULT`）、最新提交是否已通过（`HEAD_PASSED`）、下次运行会做什么（`NEXT_MODE`）、还有几个提交没审（`UNREVIEWED_COMMITS`）。不启动子代理，不跑验证。

## 启动独立角色

角色提示在 `{{SKILL_DIR}}/roles/`：`reviewer.md`、`refuter.md`、`security-reviewer.md`。

| 环境 | 启动方式 |
|---|---|
| Claude Code | Agent 工具，`subagent_type` 用 `gate-reviewer`、`gate-refuter`、`gate-security-reviewer` |
| Codex | 用 `spawn_agent` 启动自定义 agent `gate-reviewer` 等（定义在 `~/.codex/agents/`），`wait_agent` 取结果后 `close_agent` |
| Kimi Code | Agent 工具，选自定义 agent `gate-reviewer` 等 |
| ZCode | 子代理工具，选自定义 agent `gate-reviewer` 等 |
| DeepSeek Harness | `subagent` 工具（全新上下文），把对应 `roles/*.md` 的全文放在任务说明开头；不要用 `subagent_fork` |
| 其他，或找不到上面的 agent | 用任何全新上下文的子代理，同样把 `roles/*.md` 的全文放进任务说明 |

- 不要用会继承当前对话的 fork 类子代理。
- 完全没有子代理能力时，自己按角色提示依次执行，并在报告里注明"独立性降级"。
- 子代理的最后一条消息就是它的完整结果；只拿到"已完成"之类的话时，要求它把完整结果发回来。
