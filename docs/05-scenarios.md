# 05. 典型场景处理

### 场景 1: 我误改了 fork 的 master

- **会发生什么**:下次 sync 时,`compare` 返回 `ahead` 或 `diverged`,workflow 强制 PATCH 覆盖
- **怎么找回**:看 backup tag,回退到对应 SHA(详见 [04-backup-faq.md](04-backup-faq.md))
- **怎么避免**:在 fork 上改东西用新分支(比如 `my-fix`),不要改 master

### 场景 2: 我有个自己的分支不想被覆盖

- workflow 只 sync upstream **有的**分支,不会动你 fork 独有的分支
- 如果 upstream 后来也加了同名分支,就会触发 sync,你的改动会被覆盖
- **建议**:把你的分支改名成 upstream 不会用的名字(比如 `local-my-stuff`)
- 更系统的方案:用 [07-skip-mechanisms.md](07-skip-mechanisms.md) 的 `.no-sync` 机制

### 场景 3: 上游把 master 改名为 main

| 时刻 | fork 状态 |
|---|---|
| 同步前 | 有 master,无 main |
| 同步后 | **同时有** master 和 main |
| master 的内容 | 保留(upstream 删了,fork 不动) |
| main 的内容 | 跟 upstream 的 main 一样 |

**建议**:同步完后手动把 fork 的 default branch 切到 main,然后可以删 master。

### 场景 4: 上游删了某个 feature 分支

fork 上那个 feature 分支**保留**,不会被删。

### 场景 5: 上游把 dev 改成 develop

fork 上**同时存在** dev 和 develop,dev 内容不变,develop 内容跟 upstream 一样。

### 场景 6: 我想用 GPG 签名同步的 commit

本 workflow 不签名(纯 ref 操作,没有新 commit)。如果你想要签名,得改回传统的 checkout+commit+push 方式。

### 场景 7: 上游 archive 了

- `gh api` 拿不到 default_branch(返回错),触发阶段 1 的 skip 分支
- workflow 不算失败,只 warning
- fork 当前内容就是 source archive 时的内容,backup tag 都在

### 场景 8: 我同时 fork 了同一个上游的多个仓库

看 [06-multi-fork.md](06-multi-fork.md)——静态 matrix 或动态发现,一个 workflow 管所有 fork。

### 场景 9: 有个 fork 我不想自动同步

看 [07-skip-mechanisms.md](07-skip-mechanisms.md)——per-fork `.no-sync` 或 config-repo `skip.txt`。
