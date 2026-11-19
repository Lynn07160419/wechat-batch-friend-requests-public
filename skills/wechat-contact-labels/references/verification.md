# 匹配、状态与离线核对

## 任务记录

每行至少保存：来源文件指纹和图片/表格位置、原文字、人工核对后的文字、查询、当前身份依据、目标标签、状态、时间。账号标识可用本地脱敏键替代，但同一个键必须始终代表同一个已核对的账号；UI 索引、显示名和头像文件名都不是稳定账号键。

| 状态 | 含义 |
| --- | --- |
| `candidate` | 来自名单或 OCR，尚未核对当前账号 |
| `ambiguous` | 多个相同显示名或其他身份冲突 |
| `unknown` | 结果未完整读取、控件不可用、来源模糊或保存结果不明 |
| `already_member` | 操作前已从当前标签确认成员关系 |
| `selected` | 仅在本轮选择器中勾选，尚未保存 |
| `submitted_unconfirmed` | 已提交，等待成员关系核实 |
| `verified_member` | 保存后已在目标标签确认该账号 |

记录采用临时文件写完后重命名的方式保存。恢复时重读当前账号和标签，不复用旧 UI 索引；成员身份与当前标签关系确认后，再把未知状态推进到成功。来源重叠按相邻内容与位置合并；两个不同位置的同名行先保留，不能直接按名字去重。

## 可选的 JSON 核对器

`scripts/label_checks.py` 使用 Python 3.9+ 标准库，**不接触微信**。它检查调用方已收集的数据，不会替调用方确认 OCR、账号身份、结果枚举范围或数据新鲜度。

### 候选比对

将以下虚构数据保存到仓库外的 `match.json`：

```json
{
  "source_label": "27 社系示例甲",
  "results_readable": true,
  "results_complete": true,
  "candidates": [
    {"candidate_id": "account-a", "label": "27社系示例甲"}
  ]
}
```

```sh
python /path/to/wechat-contact-labels/scripts/label_checks.py match /task/match.json
```

输出 `unique_match`、`ambiguous`、`not_found` 或 `unknown`。`unique_match` 只表示完整输入集合中存在一个文字匹配，**不是点击授权或账号身份认证**。两条同名不同账号始终是 `ambiguous`；缺少完整覆盖证据始终是 `unknown`。规范化只做 Unicode NFC 与去空白，不折叠大小写、数字前缀、标点、表情或形近字。

### 成员集合验收

保存当前目标标签的基线、预期添加账号和最终枚举成员，例如 `audit.json`：

```json
{
  "baseline_complete": true,
  "baseline_member_ids": ["account-old"],
  "selected_member_ids": ["account-old", "account-a"],
  "observed_member_ids": ["account-old", "account-a"],
  "observed_count": 2,
  "members_complete": true,
  "count_stable": true
}
```

```sh
python /path/to/wechat-contact-labels/scripts/label_checks.py audit /task/audit.json
```

用账号集合的并集计算预期人数。未完整读取或人数仍变化时返回 `unknown`，稳定后集合不符则 `reconcile`，只有完整集合与人数均吻合才返回 `verified`。即使人数相等，一进一出的账号替换也会被指出。`reconcile` 只要求人工核查，不授权删除额外成员或自动补发整批。

界面人数暂时读不到时将 `observed_count` 设为 null 或省略，结果为 `unknown`；不要用可见行数冒充标签总数。输出的 `expected_new_member_count` 是计划新增数，只有状态为 `verified` 时才能把它报告为已成功新增。

未获得完整基线时把 `baseline_complete` 留为 false，不能用不完整名单计算完整验收结论。成员集合检查以账号身份正确为前提；不要用显示名冒充账号键。

CLI 成功完成检查时退出 0（不代表所有状态都是通过），输入错误退出 2。调用方必须读取 JSON 的 `status`，不能只检查退出码。
