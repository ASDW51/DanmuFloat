# PR + 远程 CI 检查流程

本机没有 Flutter/Dart 环境时，靠 GitHub Actions 完成 `flutter analyze` / `flutter test`
检查的标准流程。仓库已有 [.github/workflows/ci.yml](.github/workflows/ci.yml)，
对所有 PR 与 push 到 `main` 自动执行检查。

## 流程步骤

```bash
# 0. 准备（每次新 shell 都要做，gh 不在 PATH 且凭据不持久）
source ~/gh.sh && gh auth setup-git

# 1. 同步最新 main，从它拉出新分支（分支名 <类型>/<简短描述>）
git checkout main && git pull --ff-only
git checkout -b feat/my-feature

# 2. 开发代码，补充对应单测（与改动同分支提交）
#    本地无环境时跳过 analyze/test，交给 CI 兜底
git add <files>
git commit -m "feat: 描述"

# 3. push 到远程同名分支
git push -u origin feat/my-feature

# 4. 用 gh 创建 PR（--fill 自动取 commit 作标题/描述；也可手写 body）
gh pr create --fill

# 5. 等待 CI 结果（analyze-and-test 必须绿）
gh pr checks --watch

# 6. CI 通过后合并并删除远程分支
gh pr merge --merge --delete-branch

# 7. 回到 main 同步合并结果
git checkout main && git pull --ff-only
```

## 注意事项

- 同一分支重复 push 只会保留最新一次 CI（workflow 已配 concurrency），修问题后直接追加 commit 再 push，PR 自动重跑。
- review 后不要 force push；追加 commit 即可。
- 分支要始终从最新 `main` 拉出；若 main 有更新，可 `git fetch && git rebase origin/main` 后再 push（仅限未 review 分支）。
- 提交信息遵循 Conventional Commits 中文格式（见 AGENTS.md 第 7 节）。
- 建议在 GitHub 仓库 Settings → Branches 开启分支保护，把 `analyze-and-test` 设为合并必需 check，使「CI 绿了才进 main」成为强制约束。

## 什么情况下使用这套流程

**适用：**

1. **本机缺少 Flutter/Dart SDK 环境**，无法本地跑 `flutter analyze` / `flutter test`，用 CI 远程完成检查。
2. **本地环境与 CI 不一致**（如 Dart 版本差异导致 analyze 结果不同），以 CI 结果为准。
3. **需要留痕与可回溯**：PR 记录了改动、CI 结果与合并决策，方便 review 和回滚。
4. **多人协作或 AI 协作**：任何人/agent 都按同一门禁合入，主分支始终保持可构建。

**不必使用（可直接在 main 提交）：**

- 纯文档微调、错别字修正等不影响构建的改动（本仓库目前仍建议走 PR，成本很低）。

**不适用：**

- 紧急热修复且 CI 故障时——可临时直推 main，但事后必须补 CI 验证（CI 也会对 main 的 push 自动跑一遍）。
