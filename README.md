# WeChat Batch Friend Requests

一个面向 macOS 微信桌面版的个人 Codex 技能，用于从 XLSX、CSV 等名单安全、可恢复地处理微信好友工作流。

## 能力

- 逐条审计名单中的人员是否已在微信好友列表
- 按模板发送好友申请并设置备注
- 区分已有好友、等待验证、未找到和结果未确认
- 好友通过后发送一次性问候，避免重复消息
- 原子保存进度，支持暂停和断点恢复
- 检测微信限频、焦点错误和身份歧义并立即停止

## 安全边界

- 每次发送申请、修改备注或发送消息都需要用户在当前任务中明确授权
- 不将只读核对自动升级为发送操作
- 不绕过微信限频，不并发发送，不用姓名模糊匹配后直接添加
- 不包含任何实际名单、手机号、微信号、聊天内容或运行状态

## 使用

将仓库放在个人 Codex 技能目录 `~/.codex/skills/wechat-batch-friend-requests`。随后可在任务中使用：

```text
使用 $wechat-batch-friend-requests 处理这份报名表。先只读预检，等我确认后再发送。
```

实时操作要求：macOS、已登录的微信桌面版、Swift 编译器，以及执行 Codex 的进程拥有系统“辅助功能”权限。

详细规则见 [SKILL.md](SKILL.md)，实时操作步骤见 [references/runbook.md](references/runbook.md)。

## 文件

- `SKILL.md`：技能入口与核心不变量
- `references/runbook.md`：完整运行手册、状态模型和故障分支
- `scripts/validate_batch.mjs`：名单预检器
- `scripts/wechat_ax_action.swift`：微信 Accessibility 辅助程序
- `agents/openai.yaml`：Codex 技能界面元数据
