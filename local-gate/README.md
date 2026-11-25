# local-gate：本地评审关卡 `/gate`

这是 [agent-review-local-lite.md](../agent-review-local-lite.md) 的可安装实现，包含：

- 一个负责编排的 skill；
- 三个子代理：审查员、复核员、安全审查员；
- 一个只读 git 的辅助脚本。

支持 Claude Code、Codex、Kimi Code（kcode）、ZCode、DeepSeek Harness。全部手动触发，不用任何钩子，也不改动你的仓库。

## 目录

```text
local-gate/
├── install.sh / install.bat          # 安装脚本（macOS/Linux/Git Bash；Windows cmd/PowerShell）
├── skills/gate/                      # 安装后的 skill 目录就是它的副本
│   ├── SKILL.md                      # 编排：定范围 → 判档 → 验证 → 审查 → 预检 → 复核 → 修复 → 报告
│   ├── agents/openai.yaml            # Codex 专用：只允许显式调用
│   ├── roles/                        # 三个角色的提示（子代理定义由它们生成）
│   ├── templates/                    # 项目规则示例、报告模板、修复交接单模板
│   └── scripts/gate-helper.sh        # 确定性步骤：定范围、规则预检、记录通过、状态、导出
└── subagents/                        # 各工具子代理文件的文件头；安装时拼上 roles/*.md 的正文
```

## 安装

Windows（cmd 或 PowerShell）：

```powershell
.\local-gate\install.bat
```

```powershell
.\local-gate\install.bat --target claude codex
```

macOS / Linux / Git Bash：

```sh
sh local-gate/install.sh
```

```sh
sh local-gate/install.sh --target claude,codex
```

- 不带参数时，只装到配置目录已经存在的工具；`--target all` 会把五个工具都装上。
- 其他选项：`--uninstall` 卸载，`--dry-run` 只显示要做的操作，`--force` 覆盖不是本脚本装的同名文件。
- 重复运行就是更新。脚本只会覆盖或删除带安装标记的文件。

## 装到哪里、怎么触发

| `--target` | 工具 | skill | 子代理 | 手动触发 |
|---|---|---|---|---|
| `claude` | Claude Code | `~/.claude/skills/gate` | `~/.claude/agents/gate-*.md` | `/gate` |
| `codex` | Codex | `~/.agents/skills/gate`（共用） | `~/.codex/agents/gate-*.toml` | `$gate` |
| `kcode` | Kimi Code | `~/.agents/skills/gate`（共用） | `~/.kimi-code/agents/gate-*.md` | `/skill:gate` |
| `zcode` | ZCode | `~/.agents/skills/gate`（共用） | `~/.zcode/agents/gate-*.md` | `/gate` |
| `deepseek` | DeepSeek Harness | `~/.agents/skills/gate`（共用） | 不需要，用自带的 `subagent` 工具 | `/gate` |

- **为什么共用一份**：Codex、Kimi Code、ZCode、DeepSeek Harness 都会读 `~/.agents/skills`。各装一份的话，同一个工具里会出现两个 `gate`。卸载其中一个工具时，只要还有别的工具在用，共用的那份就会保留。
- **副作用**：其他也读 `~/.agents/skills` 的工具（比如 Cline、Warp）也能看到这个 skill，但它只能手动触发。
- **可用环境变量改目录**：`CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`KIMI_CODE_HOME`、`ZCODE_STORAGE_DIR`、`DSH_HOME`。
- **安装时会写入实际路径**：SKILL.md 里的 `{{SKILL_DIR}}` 和 `{{SH}}` 会换成真实路径。在 Windows 上，`{{SH}}` 指向 Git 自带的 `bin/sh.exe`，所以从 PowerShell 调用辅助脚本也能正常运行。

## 使用

1. 在本地提交。
2. 在工具里手动运行 `/gate`（Codex 用 `$gate`，Kimi Code 用 `/skill:gate`），后面可以跟一句改动意图。也可以指定某个提交或 `A..B` 范围。
3. 第一次在某个仓库运行时，会生成 `~/.agent-review/profiles/<仓库目录名>.yml`。请把里面的 `checks` 改成这个项目真实的命令。这份规则各工具共用。
4. 处理报告里的问题：修复要么已经写进工作区，要么在交接单里。由你或新开的会话提交，然后再运行一次 `/gate` 复查。
5. 推送前运行 `/gate status` 确认最新提交已经通过。

审查记录放在 `<仓库>/.git/agent-review/` 下，包括 `reports/`、`last.json`、`passed`、`backlog.md`、`log.jsonl`，不会被提交。

## 已验证与未验证

- **已验证**：
  - 辅助脚本在临时仓库里跑过 27 项检查，覆盖完整审查、复查、变基后只重跑验证、显式提交和范围、导出、规则预检；
  - 两个安装脚本都在临时 HOME 里装过、卸过，覆盖自动检测、`all`、部分卸载、`--dry-run`、保护别人的同名文件、`--force`、退出码；
  - 生成的 TOML 和 YAML 都用解析器检查过。
- **未验证**：还没有在这五个工具里实际运行过 `/gate`。
- **kcode**：按 Kimi Code 处理，配置目录是 `~/.kimi-code`。
- **"只能手动触发"的写法**：
  - Claude Code、Kimi Code、DeepSeek Harness 用 `disable-model-invocation: true`；
  - Codex 用 `agents/openai.yaml` 里的 `allow_implicit_invocation: false`；
  - ZCode 的程序里没找到这个字段，SKILL.md 的描述里也写明了不要自动调用。
- **子代理的写法**来自各工具的文档或安装包，各工具实际怎么调用子代理（尤其是 Codex 的 `spawn_agent` 和 ZCode）还需要在真实环境里确认。
- **Codex 子代理**会继承主会话的沙箱和审批设置；"只读 git"靠提示约束。
