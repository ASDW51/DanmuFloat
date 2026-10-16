# 标签体系

本文件说明本仓库 Issue 标签的**维度划分、判定口径与维护方式**。
标签的作用是让 `gh issue list --label ...` 一屏捞出「最该先做的」和「属于哪个模块的」，
所以每个维度只保留**能被独立判断**的少量取值，不追求覆盖面。

## 一、优先级（每个 Issue 有且只有一个）

| 标签 | 颜色 | 含义 | 判定口径 |
| --- | --- | --- | --- |
| `P0 · 紧急` | `#b60205` | 阻塞主流程或造成不可恢复的损失 | 用户的核心资产/主流程被破坏，且**没有恢复路径**（例如本地唯一数据被清空、应用直接不可用） |
| `P1 · 高` | `#d93f0b` | 主流程明显受影响 | 核心功能故障，或**界面上不存在任何出口**（例如某栏永久卡死、既不能重试也不能单独恢复） |
| `P2 · 中` | `#fbca04` | 边界场景、健壮性、性能与一致性问题 | 需要特定条件才触发，或存在绕行手段，但行为明显不符合预期 |
| `P3 · 低` | `#0e8a16` | 小瑕疵、可维护性与测试改进 | 影响面小、改动面小，或不修也不会造成错误结果 |

判定顺序建议：**先看是否可恢复**（不可恢复 → P0）→ **再看界面有无出口**（无出口 → P1）→
**再看触发条件是否苛刻**（苛刻 → P2）→ 其余为 P3。

## 二、性质（可多选，描述「是哪一类问题」）

| 标签 | 颜色 | 含义 |
| --- | --- | --- |
| `性能` | `#1d76db` | 卡顿、内存、CPU 与渲染开销 |
| `健壮性` | `#5319e7` | 异常输入、超时、资源上限等防护缺失 |
| `数据完整性` | `#006b75` | 本地落盘、备份与导入导出的正确性 |
| `测试` | `#bfd4f2` | 测试覆盖与验证门禁 |
| `隐私与合规` | `#d4c5f9` | 凭证 / 个人信息处理与免责声明等合规约束 |

## 三、区域（可多选，描述「改动会落在哪」）

区域标签的描述里写明了对应目录，便于按模块过滤；一个 Issue 可以带多个区域标签
（例如「设置项在 App 与悬浮窗两侧表现不一致」同时属于本地存储与悬浮窗）。

| 标签 | 颜色 | 对应范围 |
| --- | --- | --- |
| `区域: 悬浮窗` | `#c5def5` | `lib/ui/overlay_page.dart`、`lib/app/overlay_bridge.dart` |
| `区域: 连接与会话` | `#c5def5` | `lib/connection/`、`lib/app/live_danmu_session.dart`、`lib/danmu/sign/` |
| `区域: 弹幕处理` | `#c5def5` | `lib/danmu/` 的协议解析、过滤、滚动与展示 |
| `区域: 本地存储` | `#c5def5` | `lib/storage/` 偏好落盘、备份与导入导出 |
| `区域: 凭证与网络` | `#c5def5` | `lib/credential/`、`lib/net/`、`lib/room/` |
| `区域: 启动与合规` | `#c5def5` | `lib/main.dart`、`lib/compliance/`、权限与首启分流 |

## 四、状态（可选）

| 标签 | 颜色 | 含义 |
| --- | --- | --- |
| `待验证` | `#fef2c0` | 结论来自静态代码审查，尚未通过测试或真机确认。确认（或证伪）后请**移除**该标签，避免它长期挂在已确认的 Issue 上 |

另有一组**面向 Agent 的流转标签**（`agent:ready` / `agent:skip` / `agent:needs-review` /
`agent:in-progress` / `agent:done` / `agent:read-comments`）：它们表示的不是问题的性质，而是
「这个 Issue 该不该交给 Agent 处理、处理到哪一步」。语义、判定顺序、并发保护与注意事项见
[docs/agent-issue-protocol.md](agent-issue-protocol.md)。

## 五、GitHub 默认标签

`bug`、`documentation`、`duplicate`、`invalid`、`question`、`wontfix`、`help wanted`、
`good first issue`、`accessibility` 沿用 GitHub 默认语义，未做改动。

`enhancement` 同为 GitHub 默认标签，语义与 `feature` 重复：**新 Issue 统一用 `feature`**，
`enhancement` 仅为兼容历史保留，不再主动添加。

## 六、模板默认标签

默认标签写在**各模板自己的 YAML** 里（顶层 `labels:` 字段），不是 `config.yml`：
`config.yml` 只支持 `blank_issues_enabled` 与 `contact_links`，不承载模板标签。

| 模板 | 文件 | 默认标签 |
| --- | --- | --- |
| 缺陷报告 | `.github/ISSUE_TEMPLATE/bug_report.yml` | `bug` |
| 功能建议 | `.github/ISSUE_TEMPLATE/feature_request.yml` | `feature` |

模板只会自动带上这两个标签；优先级、性质、区域由维护者在确认后补加。

## 七、维护命令

```bash
source ~/gh.sh                      # 本机 gh 不在 PATH 且凭据不持久

# 查看全部标签
gh label list --repo ASDW51/DanmuFloat --limit 100

# 新建 / 改名（改名会同步更新所有已打该标签的 Issue）
gh label create "P2 · 中" --color fbca04 --description "边界场景、健壮性、性能与一致性问题"
gh label edit enhancement --name feature

# 给 Issue 打标签 / 移除
gh issue edit 82 --add-label "P0 · 紧急,数据完整性"
gh issue edit 82 --remove-label "待验证"

# 按维度筛选
gh issue list --label "P0 · 紧急"
gh issue list --label "区域: 本地存储" --state open
```
