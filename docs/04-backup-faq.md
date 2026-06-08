# 04. 备份与回退 + FAQ

## 备份机制

每次同步前,workflow 会在 fork 上创建一个 backup tag:

```
backup/20260602-153045-abc1234
   └─日期    └─时间   └─fork 原 SHA 前 7 位
```

**最多保留最近 20 个**,更早的自动删。**删的是 tag,不是 branch**。

---

## 🛡️ 本地修改自动备份(local-backup 分支)

**场景**:你在 fork 上某个分支直接改了东西(比如 `master` 上有 1-2 个本地 commit),忘了建独立分支。等 upstream 也有新 commit 时,workflow 会检测到 fork 和 upstream 分歧,需要处理本地提交。

**新版防护**:workflow 会先判断是否需要备份,再把 fork 当前 SHA 存到一个**备份分支**:

```
local-backup/master-20260603-153045-a1b2c3d
   └─固定前缀   └─原分支名 └─时间戳   └─原 SHA 前 7 位
```

- 命名规则:`local-backup/{原分支名}-{YYYYMMDD-HHMMSS}-{原 SHA 7 位}`
- 触发条件:upstream 有新增(`behind_by > 0`)且 fork 有本地提交(`ahead_by > 0`)
- 不触发条件:纯 `ahead`(`behind_by = 0`)表示 upstream 没有新增,workflow 会跳过,不备份也不写分支
- 去重规则:如果最近的 `local-backup/*` 分支和当前 fork 分支相对 upstream 的本地 patch 一样,跳过新备份
- 创建时机:在 force 对齐或 `merge-upstream` 前
- **不自动清理** — 本地修改是你的数据,不像 backup tag 那样只保留 20 个
- 如果本次需要备份但备份分支创建失败,该分支会跳过同步,避免在未备份时丢失本地修改

### 怎么找回本地修改

```bash
# 1. 列出所有 local-backup 分支
git branch -a | grep local-backup

# 2. 切到一个具体的备份分支看
git checkout local-backup/master-20260603-153045-a1b2c3d

# 3. 找回你的 commit (看 git log)
git log --oneline -10

# 4. 把 commit 复制到新分支
git checkout -b my-recovered-changes
git cherry-pick <commit-sha>  # 挑你想要的 commit 过来
```

### 怎么清理 local-backup 分支

推荐用 `Cleanup Local Backup Branches` 手动 workflow 清理。它有三层保护:

- 只读取 `refs/heads/local-backup/` 下的分支
- 删除前强制校验分支名必须匹配 `local-backup/*-YYYYMMDD-HHMMSS-sha7`
- 默认 `dry_run=true`,实际删除必须填 `confirm=delete-local-backup`

常用模式:

| 你想做什么 | mode | 需要填什么 |
|---|---|---|
| 只列出备份分支 | `list` | `fork` |
| 删除全部备份分支 | `delete_all` | `fork`,确认后再设 `dry_run=false` |
| 删除一个或多个指定备份 | `delete_by_name` | `backup_branches` 填一个或多个 `local-backup/...`,逗号或换行分隔 |
| 删除某个原分支的全部备份 | `delete_by_source_branch` | `source_branch` 填原分支名,如 `master` |
| 删除多余备份,每个原分支只保留最近 N 个 | `delete_keep_latest` | `keep_latest`,可选 `source_branch` |

建议流程:

1. 先用 `list` 看当前备份分支。
2. 选择删除模式,保持 `dry_run=true` 预览待删除列表。
3. 确认无误后再改成 `dry_run=false`,并填写 `confirm=delete-local-backup`。

示例:

```text
fork: my-fork
mode: delete_by_name
backup_branches:
  local-backup/master-20260603-153045-a1b2c3d
  local-backup/dev-20260604-090000-d4e5f6a
dry_run: false
confirm: delete-local-backup
```

这个 workflow 不会删除 `main`、`master`、`dev`、`sync-upstream/*`、`restore-from-backup/*` 等非 `local-backup/*` 备份分支。即使手动输入了这些分支名,也会被安全校验拦截。

### 跟 backup tag 的区别

| | `backup/*` tag | `local-backup/*` branch |
|---|---|---|
| 存什么 | fork **默认分支**同步前的 SHA | fork 任意**有 ahead commit** 的分支同步前的 SHA |
| 数量限制 | 最多 20 个,自动删 | 无限制,需要手动清理 |
| 触发 | 每次 sync 默认分支前都建 | 仅当 upstream 有新增且 fork 有本地提交时建,相同本地 patch 不重复建 |
| 用途 | 整个 fork 回退 | 找回本地修改 |
| 清理 | 自动 | 手动 workflow |

**两者不冲突,各管各的**。

---

## 怎么用 backup tag 回退

### 场景 A: 回退 fork 的 master 到同步前(命令行)

```bash
# 在你 Mac 上
git clone https://github.com/<你的用户名>/<你的-fork>.git
cd <你的-fork>
git checkout master
git reset --hard backup/20260602-153045-abc1234
git push --force-with-lease origin master
```

### 场景 B: 看 backup tag 对应的提交(网页)

GitHub 网页 → fork 仓库 → 点 "X tags" → 选 backup tag → 看 commit 历史

### 场景 C: 不想用 git 命令(网页 Revert)

GitHub 网页 → fork 仓库 → 找到 backup tag → 点 "Compare" → 选 master → 看 diff → 可以直接网页 "Create PR" 走 Revert 流程

---

## FAQ

### Q1: sync 失败 workflow 红了一片,怎么排查?

点开那次运行 → 看日志末尾的 ❌ 行,常见原因:

| 现象 | 原因 | 修复 |
|---|---|---|
| 发现到了 fork,但 PATCH/POST 失败 (403) | `FORK_SYNC_TOKEN` 未配置或没有目标 fork 写权限 | 在配置仓库 Actions secrets 新增/修正 `FORK_SYNC_TOKEN`,给目标 fork `Contents: Read and write` |
| 写 issue/report 失败 (403) | 当前配置仓库 token 权限不足 | Settings → Actions → General → Workflow permissions → 改 **Read and write**,或让 `FORK_SYNC_TOKEN` 覆盖配置仓库 |
| "上游不可访问" warning | upstream 真的删了/archived | 这是预期,等 upstream 恢复 |
| "新建分支失败" | fork 已有同名分支但被保护 | 检查分支保护规则 |
| "PATCH 失败" | fork 仓库的分支有保护规则,不允许 force | 临时关保护,跑完再开 |
| 定时任务完全不跑 | fork 默认禁用 schedule | Actions 标签页点 "I understand my workflows, go ahead and enable them" |

### Q2: 怎么改同步时间?

改 yml 里的 cron:

```yaml
schedule:
  - cron: '0 0 * * *'  # 改成你想要的
```

记得是 **UTC 时区**。当前默认是 UTC 0 点,也就是北京时间 8 点。

### Q3: 为什么不用 webhook 触发?

GitHub fork **不能配 webhook**(只有原仓库能配),所以只能用定时或手动。

### Q4: GITHUB_TOKEN / FORK_SYNC_TOKEN 权限怎么配?

配置仓库的 `GITHUB_TOKEN`: `Settings → Actions → General → Workflow permissions` → 选 "Read and write permissions"。

跨仓库同步用的 `FORK_SYNC_TOKEN`: 配置仓库 `Settings → Secrets and variables → Actions` → 新增 repository secret `FORK_SYNC_TOKEN`,值用你自己的 PAT。PAT 至少要覆盖目标 fork 的 `Contents: Read and write`;如果要写 issue 报告,还要覆盖配置仓库的 `Issues: Read and write`。

### Q5: fork 上的我自己的手动改的内容会被覆盖吗?

**会,如果你改的是 upstream 也有的分支(通常是 master/main)**。这是"严格镜像 upstream"的设计。

**不会**:
- 你在 fork 上新建的分支(upstream 没有的),完全不动
- 你 push 完后到下一次 sync 之前这段时间的改动,会保留(因为 sync 是定时)

### Q6: 想同步特定分支,不是所有分支,怎么改?

把循环里的 branch 列表过滤一下:

```bash
# 只同步 master 和 dev
for branch in $(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/branches" \
                --jq '.[] | select(.name == "master" or .name == "dev") | .name'); do
```

### Q7: 怎么禁用 backup tag 清理?

删掉"阶段 4"那段,或把 `KEPT=20` 改成超大数(比如 9999)。

### Q8: 想把 fork 的默认分支从 master 换成 main,怎么操作?

```bash
gh api -X PATCH repos/<你的用户名>/<你的-fork> \
  -f default_branch=main
```

或者在 workflow 里加一段同步完后顺便改默认分支的代码。

### Q9: workflow 一直显示 "not yet run" 不跑?

GitHub 对 **fork 仓库的定时任务默认禁用**,需要:
1. 打开 fork 的 Actions 标签
2. 看到黄色提示 "Workflows aren't being run on this forked repository"
3. 点 **"I understand my workflows, go ahead and enable them"**

**用了独立配置仓库架构(见 [01-architecture.md](01-architecture.md)),这一步就不需要了**——配置仓库不是 fork,定时任务默认开启。

### Q10: 能在 PR 合并前同步,不在合并后,能做到吗?

可以,加一个 `pull_request` trigger。但通常 PR 合并后同步更稳。

### Q11: 能在别的项目复用吗?

能。只要改 4 个 env 变量就行,代码完全通用。也可以把这套配置封装成 [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows),被其他 workflow 引用(详见 [08-advanced.md](08-advanced.md))。

### Q12: 跑一次大概多久?

- 公开 repo + 公开 upstream:**5-15 秒**(纯 API,秒级)
- 私有 repo:取决于仓库大小,可能要 30 秒+

### Q13: 我能在 fork 上有我自己的 commit 吗?

可以,但**不能放在 upstream 也有的分支名上**(会被 sync 覆盖)。

**正确做法**:
- 你的改动放在一个 **upstream 没有的分支名** 上(比如 `local-my-fixes`)
- 或者放在 fork 独有的命名空间下(比如 `<你的用户名>/my-feature`)

### Q14: 跑完之后 GitHub 邮箱会收到通知吗?

默认会。可以去 `Settings → Notifications` 调整。

### Q15: 这个 workflow 跟 GitHub 官方的 Sync fork 按钮有什么区别?

| 维度 | 网页 Sync fork 按钮 | 本 workflow |
|---|---|---|
| 触发 | 手动 | 自动定时 + 手动 |
| 范围 | 只默认分支 | 所有分支 |
| ahead commit 处理 | 要点 "Discard X commits" 多一步 | 自动丢弃 |
| 备份 | 无 | 自动 backup tag |
| 失败感知 | 看不出来 | 邮件/workflow 红 |

**可以并存**:workflow 不影响你手动点 Sync fork 按钮。
