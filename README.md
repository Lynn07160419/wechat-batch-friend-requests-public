# wechat-batch-friend-requests

面向 macOS 微信桌面版的好友与消息自动化技能：把一份名单（XLSX / CSV / JSON）变成**可核验、可中止、可恢复**的微信操作。

它优先保证「不误发」，而不是「发得快」。所有动作都走同一套校验闸门：**收件人必须完全匹配 → 同文去重 → 草稿非空即停 → 聚焦回读 → 限频检查 → 发送 → 发送后复核**。

> 这不是群发工具，也不是营销工具。它假设你已经认识名单里的人，只是需要把「核对好友、加好友、改备注、发一条消息」这些重复动作做准。

## 它能做什么

| 场景 | 行为 | 产出 |
| --- | --- | --- |
| 好友审计（只读） | 逐条搜备注、微信号、手机号，只认主搜索里的「联系人 / 最常使用」分区 | `friend` / `not_friend` / `ambiguous` |
| 发送好友申请 | 微信号优先，失败才试同一行的手机号；提交前回读申请语与备注 | `request_sent` / `already_pending` / `unresolved` |
| 已有好友 | 验身份 → 改备注 → 检查是否已问候 → 发一次问候 | `remark_updated` / `greeting_sent` |
| 定向发消息 | 按备注在主搜索里完全匹配，会话标题一致才允许输入 | `GREETING_SENT` / 已存在则跳过 |

## 为什么它不用截图

辅助程序只读 macOS Accessibility 界面树，按元素的相对位置点击，**全程不截屏**。因此：

- 微信窗口被移动、缩放、拉到副屏，不影响定位；
- 系统没给「屏幕录制」权限也能用；
- 窗口被最小化会自动还原，所有窗口都关掉会自动重开微信；
- 窄窗口下搜索框折叠成入口、AX 树短暂读空，都能自愈重试。

代价是它依赖当前微信版本的 Accessibility 标签（identifier 与 title）。微信大版本更新后标签可能变，需要先用只读命令 `search` 检查界面树再最小修补——**不要改成猜坐标**。

## 环境要求

- macOS（在 15.x 上验证）
- 已登录的微信桌面版
- Xcode Command Line Tools（提供 `swiftc`）
- Node.js 18+（仅名单预检器需要）
- 运行它的进程（Terminal / Codex / WorkBuddy）已在「系统设置 → 隐私与安全性 → 辅助功能」中被授权

## 安装

```bash
git clone https://github.com/Lynn07160419/wechat-batch-friend-requests-public.git \
  ~/.codex/skills/wechat-batch-friend-requests
```

WorkBuddy 用户把目标路径换成 `~/.workbuddy/skills/wechat-batch-friend-requests` 即可，两份目录内容一致。

## 快速开始

**1. 编译到临时目录**（不要把二进制写进技能目录）

```bash
D=$(mktemp -d)
swiftc ~/.codex/skills/wechat-batch-friend-requests/scripts/wechat_ax_action.swift -o "$D/wechat_ax_action"
```

**2. 只读确认界面可读、收件人唯一**

```bash
"$D/wechat_ax_action" check-friend '某个备注'
# {"titles":["某个备注 9.30"],"localCount":1,"result":"friend_check"}
```

`localCount` 为 1 才能继续；大于 1 是歧义，必须停下让用户确认。

**3. 演练一次，不发送**

```bash
WECHAT_AX_DRY_RUN=1 "$D/wechat_ax_action" main-search-and-greet '某个备注 9.30' '要发的文本'
# RESULT=DRY_RUN_OK —— 只输入并回读，随后撤掉草稿
```

**4. 正式发送**

```bash
"$D/wechat_ax_action" main-search-and-greet '某个备注 9.30' '要发的文本'
# RESULT=GREETING_SENT
```

注意第一步的参数是**完整备注名**，不是模糊关键词。`main-search-and-greet` 要求「搜索词 = 搜索结果标题 = 会话标题」三者完全一致，只传「某个备注」会被判为不匹配而拒绝执行。这是防误发的设计，不是 bug。

## 名单格式与预检

把表格读成 JSON 数组（标识符保持文本，保留前导零），再跑预检：

```bash
node scripts/validate_batch.mjs examples/batch.sample.json
```

```json
{
  "config": {
    "remarkTemplate": "面试{grade}{department}{name}",
    "requestText": "好友申请语",
    "greetingText": "通过后的问候"
  },
  "records": [
    {
      "sheet": "示例名单",
      "row": 2,
      "name": "张示例",
      "department": "信息管理系",
      "grade": "25本",
      "wechat": "example_zhang",
      "phone": "13800000001",
      "remark": "面试25本信息管理系张示例"
    }
  ]
}
```

预检会拦下：缺姓名、缺可检索标识、缺备注、`sheet + row` 重复、标识符重复、备注重复、备注与 `remarkTemplate` 不一致。备注超过 64 字只给警告（微信可能截断）。

`examples/batch.sample.json` 是可直接跑通的占位样例，没有任何真实数据。

## 命令参考

| 命令 | 说明 |
| --- | --- |
| `check-friend QUERY` | 只读：返回本地联系人命中数（JSON） |
| `search TEXT` | 只读：输入主搜索并回读 |
| `click-title` / `click-id` | 点击标题 / 标识符命中的元素 |
| `press-title` / `press-id` | 对元素发送 AXPress |
| `process-one CONTACT REQUEST REMARK` | 添加朋友并提交申请 |
| `process-existing-friend CONTACT REMARK GREETING [ACCOUNT] [NAME]` | 已有好友：验身份 → 改备注 → 发问候 |
| `save-open-profile-remark ACCOUNT REMARK` | 在已打开的资料页改备注 |
| `main-search-and-greet REMARK GREETING` | 主搜索精确定位会话后发问候 |
| `greet-current-chat REMARK GREETING` | 在当前会话发问候（须标题完全匹配） |
| `remove-chat-draft-prefix TEXT` | 仅移除本次注入的草稿前缀 |

不带参数运行会打印以上用法。环境变量 `WECHAT_AX_DRY_RUN=1` 让发问候走演练模式。

退出码：`70` 命中限频，必须整批硬停；`71`–`74` 主搜索 / 会话定位失败；`80`–`82` 草稿清理失败；`91` 资料页账号不匹配；`123` 搜索聚焦或回读失败。

## 安全与隐私

- **授权按任务计**：只读核对不会被自动升级为发送。每次发申请、改备注、发消息都需要当次明确授权。
- **失败不重试**：结果不明确一律记 `unconfirmed`，绝不自动重发；看到「等待验证」视为已有申请。
- **限频硬停**：出现「操作太频繁」「请稍后再试」，立刻停止整批，不加速、不换号、不绕限制。
- **单线程**：逐人处理，每人完成并原子写入状态后才进入下一条。
- **本地运行**：不联网、不上传、不存任何凭据；仓库里没有真实名单、手机号、微信号或聊天内容。
- **不猜身份**：多条本地结果、身份不匹配、聊天框已有草稿、界面结构变化，全部停止当前行交由人判断。

## 已知限制

- 只支持 macOS 桌面版微信；Windows 与网页版不适用。
- 依赖当前微信版本的 Accessibility 标签，微信大版本更新后可能需要修补。
- 需要「辅助功能」权限；没有该权限时只能做 JSON 预检。
- 不是官方 API。过度频繁的自动化操作仍可能触发微信风控，请自行控制节奏。

## 目录结构

```
.
├── SKILL.md                     # 技能入口与核心不变量
├── references/runbook.md        # 完整运行手册、状态模型与故障分支
├── examples/batch.sample.json   # 占位样例，可直接跑通预检
├── scripts/
│   ├── validate_batch.mjs       # 名单预检器
│   └── wechat_ax_action.swift   # 微信 Accessibility 辅助程序
└── agents/openai.yaml           # 技能界面元数据
```

## License

[MIT](LICENSE)

---

### English summary

A macOS-only automation skill for the WeChat desktop client. It turns a roster (XLSX / CSV / JSON) into verifiable, resumable WeChat operations: friend-status audit, templated friend requests, remark updates, and one-shot greetings.

It drives WeChat through the macOS Accessibility tree instead of screenshots, so window movement, zooming, and missing screen-recording permission do not break it. Every send path shares one gate: exact recipient match, duplicate-text guard, non-empty draft stop, focused read-back, rate-limit check, then post-send verification. Any ambiguous outcome is marked `unconfirmed` and never auto-retried. Requires macOS, a logged-in WeChat, Xcode Command Line Tools, and Accessibility permission for the host process.
