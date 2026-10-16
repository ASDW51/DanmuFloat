# Agent Issue 处理协议（标签驱动）

> 面向「让 agent 去处理仓库 Issue」这一场景：**只按标签做决策**，不靠标题猜意图。
> 标签的完整体系（优先级 / 性质 / 区域 / 状态）见 [docs/labels.md](labels.md)；
> 本文件定义 `agent:*` 一族标签的语义、流转与注意事项。
> 状态：**已定稿**，7 项关键决策见第九节。

一句话规则：**只有带 `agent:ready`、且不带 `agent:skip` / `agent:in-progress` / `agent:done` 的
Issue 才可以自动开工；带 `agent:read-comments` 的必须先读评论区再动手。**

## 一、标签语义与 Agent 行为

| 标签 | 颜色 | 含义 | Agent 行为 |
| --- | --- | --- | --- |
| `agent:ready` | `#0E8A16` | 已就绪，Agent 可自动读取并执行 | 纳入待处理队列 |
| `agent:skip` | `#6A737D` | 明确忽略此 Issue | 直接跳过，**不读取** |
| `agent:needs-review` | `#FB8500` | 需要人工确认后再决定 | 暂停，等待人工处理 |
| `agent:in-progress` | `#1D76DB` | 正在处理中（防止并发重复） | 其他 Agent 跳过 |
| `agent:done` | `#8250DF` | 已处理完成 | 不再读取 |
| `agent:read-comments` | `#0F766E` | 修复注意点在评论区 | 读取时**强制**拉取 comments 字段 |

`agent:read-comments` 是**修饰标签**：它自己不代表可处理，也不会让一个 `skip` 的 Issue 变成可处理。

## 二、判定顺序（多个标签并存时按此裁决）

1. `agent:skip` —— 最高优先级，直接跳过，连正文都不读；
2. `agent:needs-review` —— 暂停，交回人工；
3. `agent:in-progress` —— 已有 Agent 在做，跳过（避免重复改动互相踩）；
4. `agent:done` —— 已完结，不再读取；
5. `agent:ready` —— 可以开工；
6. **无任何 `agent:*` 标签 → 完全无视**：不入队、不处理、也不留提示（未分诊的 Issue 视为
   还没打算交给 Agent，等人工补标签即可；见第九节决策 1）。

裁决顺序存在的意义：标签是人工随手加的，冲突一定会发生（例如先标 `ready` 后来又发现要
人工确认而补了 `needs-review`，却忘了摘掉 `ready`）。**冲突时不需要报错，按顺序执行即可**，
但应在收尾时留一句评论说明按哪个标签执行了。

## 三、谁设置哪个标签

| 标签 | 设置者 | 时机 |
| --- | --- | --- |
| `agent:ready`、`agent:skip`、`agent:needs-review`、`agent:read-comments` | 维护者（人工） | 分诊 Issue 时 |
| `agent:in-progress`、`agent:done` | Agent | 开工时 / 完成时 |

- Agent **不得**自行把 Issue 标成 `ready`（否则等于自己给自己派活，人工分诊失效）；
- Agent **不得**擅自移除人工设置的 `skip` / `needs-review` / `done`（发现判断有误时，留评论
  交回人工）；
- 处理结束必须摘掉 `agent:in-progress`（它是租约，不是历史记录）。

## 四、标准流程

```bash
source ~/gh.sh                       # 本机 gh 不在 PATH，凭据也不持久
R=ASDW51/DanmuFloat

# 1) 拉候选：默认不拉评论正文，省流量也避免误读（见第六节）
gh issue list --repo "$R" --state open --limit 200 \
  --json number,title,labels,updatedAt \
  --jq '[.[] | {n:.number, t:.title, u:.updatedAt, l:[.labels[].name]}]
        | map(select((.l|index("agent:skip"))|not))
        | map(select((.l|index("agent:needs-review"))|not))
        | map(select((.l|index("agent:in-progress"))|not))
        | map(select((.l|index("agent:done"))|not))
        | map(select((.l|index("agent:ready"))!=null))
        | sort_by(.u)'          # 最后更新最早者排在前面（第九节决策 2）

# 2) 选一个：先看优先级（P0 > P1 > P2 > P3），同优先级取 updatedAt 最早者
#    —— 最久没动的先做，避免老 Issue 被新 Issue 不断插队
#    优先级标签形如 "P0 · 紧急"，用 gh issue view <n> --json labels 确认

# 3) 认领：先占位，再复查（见第五节）
gh issue edit <n> --repo "$R" --add-label "agent:in-progress"
gh issue view <n> --repo "$R" --json labels --jq '[.labels[].name]|join(",")'

# 4) 仅当带 agent:read-comments 时：读全评论区
gh issue view <n> --repo "$R" --comments

# 5) 收尾（成功）
gh issue edit <n> --repo "$R" --add-label "agent:done" --remove-label "agent:in-progress"

# 5') 收尾（失败 / 阻塞 / 需要人工决策）
gh issue comment <n> --repo "$R" --body "阻塞原因：…（已尝试 …，建议 …）"
gh issue edit <n> --repo "$R" --add-label "agent:needs-review" --remove-label "agent:in-progress"
```

## 五、并发保护：为什么必须「先标后干」

GitHub 的标签接口**不是原子的 compare-and-set**：两个 Agent 同时读到 `ready` 时都可能开工。
因此认领必须走：

1. 先 `--add-label agent:in-progress`；
2. **再拉一次 labels 复查**：若看到 `in-progress` 的时间/内容像是别人刚加的，或维护者已在
   评论里指派了别人，就让出（`--remove-label agent:in-progress` 并跳过）；
3. 干活期间一直保留 `in-progress`；
4. 完成后 `+done` / `-in-progress`。

注意：重复添加同一标签是幂等的（不会报错），所以**不能靠"加标签失败"判断抢到了**，
必须靠第 2 步复查；同时**一个 Agent 一次只认领一个 Issue**（第九节决策 3）。

**租约不会自动过期**：本协议不设 `in-progress` 超时回收（第九节决策 4）。若某个 Agent 崩溃
导致标签滞留，只能由**维护者人工**摘除后重新分诊；其他 Agent 不得擅自摘掉别人的
`in-progress`：

```bash
gh issue edit <n> --repo "$R" --remove-label "agent:in-progress"
```

## 六、注意点（动手前逐条过）

1. **`agent:read-comments` 是强制的**：正文之外的修复注意点（复现条件、指定方案、"这条先别按
   正文改"）通常写在评论里。命令要带 `--comments`，读完再动手。
2. **默认不拉评论正文**：没有该标签时，列表阶段就不要 `--json comments`（负载大且容易把
   闲聊当需求）；确实需要上下文时再按 Issue 拉。
3. **别把标签当"已修复"的证据**：`done` 只表示「有人处理过」，完成定义见第七节。
4. **一次一个**：同时认领多个 Issue 会让 `in-progress` 失去意义，也让改动互相踩。
5. **本仓库硬边界**（DanmuFloat）：纯弹幕查看器，不做登录 / 发弹幕 / 打赏；不改 `third_party/`
   下 Dart 风格；禁止 `dart format`；不提交 `android/key.properties`、`*.jks` 等凭证文件；
   免责声明等合规入口不可弱化。详细规范见 [AGENTS.md](../AGENTS.md) 与
   [CONTRIBUTING.md](../CONTRIBUTING.md)。
6. **合规 / 隐私类先回人工**：带 `隐私与合规` 标签的 Issue（凭证处理、免责声明、数据清除）默认
   加 `needs-review`，不要自动开工。
7. **不要为了"清空队列"而关 Issue**：关不关 Issue 由维护者决定；Agent 只更新标签、留评论、
   提 PR。
8. **`agent:*` 只用于 Issue，不用于 PR**（第九节决策 6）：PR 的状态由 CI / review / merge
   表达，再叠一套标签只会与 Issue 的语义混淆。
9. **`done` 之后不自动返工**（第九节决策 5）：复查发现问题时由维护者摘掉 `done` 并重新标
   `ready`，不新增 `agent:reopen`；Agent 不得自行摘 `done`。

## 七、完成的定义

一个 Issue 算「处理完成」需要同时满足：

- 有对应 PR，且 PR 正文写了 `Closes #<n>`（或 `Fixes #<n>`）；
- PR 上的 CI（`flutter analyze` + `flutter test`）**绿**；
- 若原 Issue 带 `待验证` 标签：只有在测试或真机确认后才移除它（没验证就留着）；
- 收尾标签：`+agent:done` / `-agent:in-progress`。

## 八、与其它标签维度的配合

| 维度 | 对 Agent 的作用 |
| --- | --- |
| 优先级 `P0`–`P3` | 决定处理顺序；`P0 · 紧急` 应立即处理或先回人工 |
| 性质（`性能` / `健壮性` / `数据完整性` / `测试` / `隐私与合规`） | 决定要注意的点；`隐私与合规` 直接转人工 |
| 区域（`区域: …`） | 决定先读哪些目录，缩小检索范围 |
| `待验证` | 参与完成定义（第七节） |
| `good first issue` | 说明改动面小，适合新手或轻量 Agent |

## 九、已定稿的关键决策

以下 7 点由维护者拍板，作为本协议的定稿依据（保留在此，便于日后回溯"为什么这么定"）：

| # | 决策点 | 结论 | 理由 |
| --- | --- | --- | --- |
| 1 | 无 `agent:*` 标签的 Issue | **完全无视**：不入队、不处理、不提示 | 未分诊 = 还没打算交给 Agent，宁可少做也不做错 |
| 2 | 同优先级排序 | **最后更新最早者优先** | 老 Issue 不会被新 Issue 无限插队 |
| 3 | 并发上限 | **一个 Agent 一次只认领 1 个** | `in-progress` 语义清晰，改动互不干扰 |
| 4 | `in-progress` 超时回收 | **不做超时回收**，仅由维护者人工摘除 | 避免正常长任务被误判失效、误抢；代价是崩溃后需人工介入 |
| 5 | `done` 之后返工 | **维护者摘 `done` 并重新标 `ready`**，不新增 `agent:reopen` | 返工由人工控制，避免 Agent 自己给自己开单 |
| 6 | `agent:*` 适用范围 | **只用于 Issue**，不用于 PR | PR 已有 CI / review / merge 状态，叠加标签会混淆语义 |
| 7 | 文档挂载点 | 链进 [docs/labels.md](labels.md) 第四节与 [docs/dev-playbook.md](dev-playbook.md) 附录 A | 与现有文档地图一致，避免后来者重复造轮子 |

**已知代价**（明确接受，不修）：决策 4 意味着某个 Agent 崩溃后 `in-progress` 会一直挂着，直到
人工发现并摘除；决策 1 意味着未打标签的 Issue 会静默积压，需要维护者定期分诊。
