# 03. API 端点 + 执行流程 + 状态决策表

## 核心 API 端点说明

本 workflow 用到 4 个 GitHub REST API 端点,全部走 `gh api` 命令。

### 1. `GET /repos/{owner}/{repo}` - 拿仓库元信息

```bash
gh api repos/cv-cat/Spider_XHS --jq '.default_branch'
```

**返回**:`{ "default_branch": "master", "fork": false, ... }`

**用途**:检测上游是否存活 + 拿默认分支名

---

### 2. `POST /repos/{fork}/merge-upstream` - 同步 fork (官方接口)

```bash
gh api -X POST repos/Link-Start/Spider_XHS_cv-cat/merge-upstream \
  -f branch=master
```

**用途**:把 fork 的某分支快进到 upstream(官方 "Sync fork" 按钮背后的 API)
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

### 4. `PATCH /repos/{fork}/git/refs/heads/{branch}` - 强制更新分支

```bash
gh api -X PATCH repos/Link-Start/Spider_XHS_cv-cat/git/refs/heads/master \
  -f sha=abc1234 -f force=true
```

**用途**:强制把 fork 的某分支指向指定 SHA(等价于 `git push --force`)
**关键参数**:`force=true` 允许非快进(会丢弃 fork 独有的 commit)

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

整个 workflow 分 **5 个阶段**:

```
┌──────────────────────────────────────────────┐
│ 阶段 1: 上游存活检查                          │
│   gh api repos/<upstream>                    │
│   拿不到 → exit 0 + warning (不算 fail)       │
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
│         diverged   → 去重备份后 force/keep    │
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
| `diverged` | 双向分歧 | 你改了 fork, upstream 也改了 | 去重备份后按 `discard_local_changes` 处理 | `force` 强制对齐;`keep` 尝试 `merge-upstream` |

**只有 upstream 有新增且 fork 有本地提交时才会创建 `local-backup/*`**。如果最近备份里已经有相同本地 patch,不会重复创建备份分支。

**想保留 fork 上的某些独有 commit**:
- 把它们 commit 到 upstream 不会用的分支名 (比如 `local-my-changes`)
- 或者把 `discard_local_changes` 设为 `keep`,让 workflow 在分歧时尝试保留本地 commit
- 已经被 force 覆盖的本地 commit,用 `local-backup/*` 找回来(见 [04-backup-faq.md](04-backup-faq.md))
