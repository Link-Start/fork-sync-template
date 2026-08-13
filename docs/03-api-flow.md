# 03. API 端点 + 执行流程 + 状态决策表

## 核心 API 端点说明

本 workflow 使用 GitHub REST API。`discard_local_changes: force` 会直接把 fork ref 强制更新到 upstream SHA,实现 GitHub `Discard commits` 的最终状态。

### 1. `GET /repos/{owner}/{repo}` - 拿仓库元信息 / 验证 upstream 可访问性

```bash
gh api repos/cv-cat/Spider_XHS --jq '.default_branch'
```

**返回**:`{ "default_branch": "master", "fork": false, ... }`

**用途**:检测上游是否真实可访问 + 拿默认分支名、仓库大小等信息。

**关键保护**:即使 fork 元数据里还残留 `parent.default_branch`,也必须再直接 GET upstream 仓库本体。如果这里返回 404/403/不可读,说明源码库当前对 token 不可访问,workflow 会先保护备份 fork 默认分支,然后跳过同步,不会继续拉 branches / compare / Discard commits。

常见含义:

| API 结果 | 处理 | 常见原因 |
|---|---|---|
| 200 | 继续同步流程 | upstream 可访问 |
| 404 | 保护备份后跳过 | 源仓库删除、私有化无权限、改名但 fork 元数据残留、owner 不可见、token 无权限 |
| 403 | 保护备份后跳过 | token 权限不足、组织 SSO/策略限制、私有仓库无权限、API 限制 |
| `default_branch` 为空 | 保护备份后跳过 | 空仓库、源码不可用、默认分支不可读 |

---

### 2. `POST /repos/{fork}/merge-upstream` - 快进同步 fork

```bash
gh api -X POST repos/Link-Start/Spider_XHS_cv-cat/merge-upstream \
  -f branch=master
```

**用途**:把 fork 的某分支快进到 upstream
**限制**:**只能快进**,如果 fork 有 ahead commit 会返回 422

---

### 3. `GET /repos/{fork}/compare/{base}...{head}` - 比较两个分支

```bash
gh api repos/Link-Start/Spider_XHS_cv-cat/compare/cv-cat:Spider_XHS:master...master \
  --jq '{status, ahead_by, behind_by}'
```

**返回**:
```json
{
  "status": "diverged",   // identical | ahead | behind | diverged
  "ahead_by": 1,          // fork 比 upstream 多几个
  "behind_by": 3          // fork 比 upstream 少几个
}
```

**用途**:智能判断 ahead/behind 状态,决定走哪条同步路径

**URL 解析**:
- `{fork}` = URL 里的 repo,head 从这里来
- `{base}` = 跨仓库的 base,用 `owner:repo:branch` 格式
- `{head}` = 同仓库的 head,直接写 `branch` 即可

---

### 4. `PATCH /repos/{fork}/git/refs/heads/{branch}` - Discard commits

```bash
gh api -X PATCH repos/Link-Start/Spider_XHS_cv-cat/git/refs/heads/master \
  -f sha=abc1234 -F force=true
```

**用途**:执行和 GitHub 网页 `Discard commits` 一样的最终状态,把 fork 分支 hard reset 到 upstream 分支 SHA
**效果**:fork 独有 commit 会被丢弃;本 workflow 会先创建 `local-backup/*` 备份分支
**关键参数**:`-F force=true` 以布尔值传递 `force`,允许非快进(会丢弃 fork 独有的 commit)

---

### 5. `POST /repos/{fork}/git/refs` - 创建新 ref

```bash
gh api -X POST repos/Link-Start/Spider_XHS_cv-cat/git/refs \
  -f ref=refs/heads/dev \
  -f sha=def5678
```

**用途**:在 fork 上创建新分支(从 upstream 拉新分支时用)

---

## 执行流程详解

### 顶层: 三阶段模型 (workflow 层面)

整个 workflow 每天拆成三个独立的定时阶段,通过 `workflow-state` 分支的 `fork-registry.json` 注册表串联。**关键优化:阶段1 只对"候选 fork"做 compare,阶段2 只同步"有更新的 fork"**,不再每次全量 discover + 全量 compare,省配额:

```
┌──────────────────────────────────────────────┐
│ 阶段1 (每天 08:00 北京) check-updates.sh      │
│   - 每 full_check_interval_days 天全量重检:   │
│     discover 所有 fork + 逐个 enrich          │
│     → 重建 syncable / unsyncable / new 列表   │
│   - 其余每天轻量 diff:                        │
│     对比 fork 列表,识别新 fork + 移除的 fork   │
│   - 对 syncable + new 的 fork 用 compare      │
│     检测是否有更新 (compare_batch_size 分批)   │
│   - 有更新的按 sync_batch_size 分批            │
│     → registry.pending_batches               │
└──────────────────┬───────────────────────────┘
                   ↓
┌──────────────────────────────────────────────┐
│ 阶段2 (每天 09:00 北京) sync-each-fork.sh     │
│   - 读 registry.pending_batches              │
│   - 逐批并发同步 (每批后查配额,低于安全线提前结束)│
│   - 新 fork 同步成功 → 移入 syncable           │
│   - 失败 → run 末尾重试一次                   │
│   - 仍失败 → 写入 registry.retry_failed       │
│   (每 fork 内部的 5 阶段流程见下方)            │
└──────────────────┬───────────────────────────┘
                   ↓
┌──────────────────────────────────────────────┐
│ 阶段3 (每天 20:00 北京) retry-failed.sh       │
│   - 读 registry.retry_failed                 │
│   - 逐个重试一次                              │
│   - 成功 → 从列表移除;失败 → failures+1       │
│   - 达 retry_alert_threshold → 告警列表       │
└──────────────────────────────────────────────┘
```

手动触发 (`workflow_dispatch`) 按顺序跑完三个阶段,方便一次性测试。

### 单 fork 内部: 5 阶段同步流程 (fork-worker.sh)

阶段2 里每个 fork 的处理仍分 **5 个阶段**:

```
┌──────────────────────────────────────────────┐
│ 阶段 1: 上游存活检查                          │
│   gh api repos/<upstream>                    │
│   404/403/不可读 → 保护备份 + skip            │
│   parent 元数据残留但 upstream 404 也会拦截    │
└────────────────┬─────────────────────────────┘
                 ↓
┌──────────────────────────────────────────────┐
│ 阶段 2: 备份当前 fork 默认分支                  │
│   拿 fork 默认分支当前 SHA                     │
│   POST git/refs 建 backup/<时间>-<sha> tag   │
└────────────────┬─────────────────────────────┘
                 ↓
┌──────────────────────────────────────────────┐
│ 阶段 3: 遍历 upstream 所有分支同步             │
│   for branch in upstream.branches:           │
│     拿 upstream SHA                           │
│     看 fork 有没有                             │
│       没有 → POST 新建                        │
│       有 → compare API 决策                   │
│         identical  → 跳过                     │
│         behind     → merge-upstream 快进      │
│         ahead      → upstream 无新增,跳过     │
│         diverged   → 去重备份后 Discard/keep  │
└────────────────┬─────────────────────────────┘
                 ↓
┌──────────────────────────────────────────────┐
│ 阶段 4: 清理旧 backup tag (保留 20 个)        │
│   列出所有 backup/* tag                       │
│   按时间倒序                                  │
│   删第 21 个及更早的                          │
└────────────────┬─────────────────────────────┘
                 ↓
┌──────────────────────────────────────────────┐
│ 阶段 5: 汇总输出                              │
│   打印 新建/同步/失败 数                       │
│   有失败 → exit 1 (workflow 红)              │
│   都成功 → exit 0 (绿)                        │
└──────────────────────────────────────────────┘
```

---

## 状态决策表

`compare` API 返回 4 种 `status`,对应不同处理:

| `status` | 含义 | fork 现状 | workflow 动作 | 备注 |
|---|---|---|---|---|
| `identical` | 完全一致 | 一模一样 | 跳过 | 啥都不做 |
| `behind` | fork 落后 | upstream 多了 commit, fork 没动 | `merge-upstream` 快进 | **最干净,无 merge commit** |
| `ahead` | fork 超前 | 你手动改了 fork, upstream 没动 | 跳过 | upstream 无新增,不备份也不写分支 |
| `diverged` | 双向分歧 | 你改了 fork, upstream 也改了 | 去重备份后按 `discard_local_changes` 处理 | `force` 执行 `Discard commits`;`keep` 尝试 `merge-upstream` |

**只有 upstream 有新增且 fork 有本地提交时才会创建 `local-backup/*`**。如果最近备份里已经有相同本地 patch,不会重复创建备份分支。

**想保留 fork 上的某些独有 commit**:
- 把它们 commit 到 upstream 不会用的分支名 (比如 `local-my-changes`)
- 或者把 `discard_local_changes` 设为 `keep`,让 workflow 在分歧时尝试保留本地 commit
- 已经被 `Discard commits` 覆盖的本地 commit,用 `local-backup/*` 找回来(见 [04-backup-faq.md](04-backup-faq.md))
