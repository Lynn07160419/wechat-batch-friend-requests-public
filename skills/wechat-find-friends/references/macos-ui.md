# macOS 微信界面检索

## 工具选择

先检查本次可用连接器和本地查询工具。若使用 `wechat-chat-export`，先运行其 `doctor`；缺数据库密钥时切换到 UI 或现成资料，不在查人流程里临时做系统级取钥。不要把数月前的解密库当作当前通讯录。

没有足够接口时可用当前环境的原生 UI 工具。附带的 `scripts/wechat_ax_query.swift` 也能在获得 macOS 辅助功能权限的环境中读取 AX 树及操作检索控件。它不提供发送消息或修改备注的专用命令；通用点击仍须限定在本任务已观察到的检索/查看入口。

编译到任务临时目录：

```sh
swiftc /path/to/wechat-find-friends/scripts/wechat_ax_query.swift -o /task/wechat-query
/task/wechat-query --help
/task/wechat-query dump > /task/ui.json
/task/wechat-query search '已知的消息短语'
/task/wechat-query check-friend '已知的联系人标识'
```

不要把完整 AX 树反复打印到对话里；它含有当前聊天和其他可见会话内容。保存本地，只提取当前步骤所需的控件、计数或匹配信息。

若辅助程序报告遍历超限，后续操作已停止，不能把缺失结果当作不存在。改用能读取目标窗口的现有 UI 工具，或在确认属于本任务后关闭多余查看窗口，再重新读取。

主窗口按聊天控件或主搜索结果控件识别，不要求标题恰好是“微信”。有多个候选窗口时停止。唯一主窗口被最小化时，搜索入口可还原该窗口；不会还原所有窗口或重启微信。窄窗口的搜索入口可展开一次，然后用刷新后的树重试；不要复用展开前的路径。

## 搜索与枚举

- `search TEXT` 操作主窗口搜索；`search-history TEXT` 只操作已打开的“搜索聊天记录”窗口；`search-member TEXT` 操作群成员搜索。三者不要混用。
- 依据当前 UI 树定位搜索结果。已观察到的版本常用 `search_item_<显示名>`、`search_list`、`chat_message_list`，但不能假定未来版本不变。
- `click AXIdentifier ID` 或 `click path AX_PATH` 只用于刚刚观察到的、唯一的目标。路径会随弹窗变化；不要从上一个人的树复用坐标或路径。
- 点击后等待布局稳定，再读一次树。控件框大小为零或会话标题不符时不要继续点击。
- 搜索结果、群成员列表和聊天内容可能只暴露当前可见行。维护去重集合与覆盖位置；滚动后等待数据加载再读取。滚动方向应实测一次，不凭不同工具中 `up/down` 的命名猜测。
- 每个候选同时检查聊天前段和后段，补齐中间缺口。只有欢迎语和最后几条消息不足以排除中间的自我介绍。

`check-friend TEXT` 先输入并回读查询，再按分区输出 `friend_check`、`localCount` 和 `matches`。只计“联系人／最常使用”，不把群聊、聊天记录或网络结果算作好友。输出明确标注 `scope: visible_results`：计数是当前可见行，不是通讯录总数；`0` 也不自动等于“不是好友”。需要结合完整枚举和其他精确标识核对。

结果列表缺失、分区不认识、坐标不可读、主窗口不唯一均返回 `search_error`（退出码 `123`），不得记成零匹配。限频返回 `rate_limit`（退出码 `70`），停止整个 UI 批次。普通输入、聚焦、回读错误也保留为未知，不自动发送或改备注。

可离线检查之前保存的树，或用合成数据做回归测试；该命令不访问微信：

```sh
/task/wechat-query inspect-snapshot /task/ui.json
```

离线快照只说明采集时的界面，不能替代恢复任务后的实时身份核验。

```sh
/task/wechat-query click AXIdentifier '刚观察到的结果ID'
/task/wechat-query scroll AXIdentifier chat_message_list -12
/task/wechat-query dump > /task/chat-part.json
```

## 资料页和群昵称

已观察到的版本中，`current_chat_name_label` 是会话标题；私聊侧栏的 `single_chat_member_cell` 可打开资料页。资料页常见：

- `display_name_text`：当前显示名/备注。
- `微信号：` 标签后的 `ProfileTextView`：可修改的公开账号标识，未必是内部 username。
- `群昵称：`：从特定群成员资料进入时，可能显示此账号在该群的自报名称。
- `value_remark_view`：备注编辑入口，只在补备注已获授权时使用。

从群里打开成员资料后，核对账号与先前私聊一致再使用群昵称。没有显示群昵称只能说明本次资料页未提供额外信息。

## 失焦与中断

辅助程序只向已核验的搜索框输入，不向聊天输入框输入。即使文本是欢迎语，也只是搜索；不要使用回车提交消息来“测试”。搜索失焦后重新读树，允许一次只读恢复；不要无限循环抢焦点。

登录失效时保存进度，等待用户恢复登录。恢复后重认账号。遇到限频停止该 UI 批次；不切换账号、不断重试或尝试绕过。与用户或其他任务争用微信时先做本地离线工作。

## 已授权的备注更新

优先复用已安装的 `wechat-batch-friend-requests` 的 `save-open-profile-remark EXPECTED_ACCOUNT NEW_REMARK`，并按其 runbook 打开备注编辑器。它是备注专用入口，不会连带问候。传参用结构化参数数组，不把账号或备注插入未经转义的 shell 文本。

保存前后均核验资料页账号；保存后回读备注。先形成字段依据和具体新备注即可执行已有授权，无须逐人再问。不要调用 `process-existing-friend` 等会同时发送问候的入口来完成纯备注任务。
