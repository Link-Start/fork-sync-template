# 04. 备份与回退 + FAQ

## 备份机制

每次同步前,workflow 会在 fork 上创建一个 backup tag:

```
backup/20260602-153045-abc1234
   └─日期    └─时间   └─fork 原 SHA 前 7 位
```

**最多保留最近 20 个**,更早的自动删。**删的是 tag,不是 branch**。

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
| 所有 `gh api` 全失败 (403) | GITHUB_TOKEN 没 write 权限 | Settings → Actions → General → Workflow permissions → 改 **Read and write** |
| "上游不可访问" warning | upstream 真的删了/archived | 这是预期,等 upstream 恢复 |
| "新建分支失败" | fork 已有同名分支但被保护 | 检查分支保护规则 |
| "PATCH 失败" | fork 仓库的分支有保护规则,不允许 force | 临时关保护,跑完再开 |
| 定时任务完全不跑 | fork 默认禁用 schedule | Actions 标签页点 "I understand my workflows, go ahead and enable them" |

### Q2: 怎么改同步时间?

改 yml 里的 cron:

```yaml
schedule:
  - cron: '0 2 * * *'  # 改成你想要的
```

记得是 **UTC 时区**。想北京时间 8 点 = UTC 0 点,改成 `'0 0 * * *'`。

### Q3: 为什么不用 webhook 触发?

GitHub fork **不能配 webhook**(只有原仓库能配),所以只能用定时或手动。

### Q4: GITHUB_TOKEN 权限怎么开?

`Settings → Actions → General → Workflow permissions` → 选 "Read and write permissions"。

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
                --jq -r '.[] | select(.name == "master" or .name == "dev") | .name'); do
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
