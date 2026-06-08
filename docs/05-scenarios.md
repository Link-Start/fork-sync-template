# 05. 典型场景处理

### 场景 1: 我误改了 fork 的 master

- **upstream 没有新增时**:`compare` 返回 `ahead`,workflow 会跳过,不备份也不写分支
- **upstream 也有新增时**:`compare` 返回 `diverged`,workflow 会先检查最近的 `local-backup/*`;如果本地 patch 已经备份过就跳过新备份,否则创建 `local-backup/master-{时间戳}-{sha7}` 保存你的本地 commit
- **之后怎么同步**:`discard_local_changes: force` 会在备份后执行 GitHub `Discard commits`,把 fork 对齐 upstream;`discard_local_changes: keep` 会在备份后尝试 `merge-upstream` 保留本地 commit
- **怎么找回**:
  1. 简单:`git checkout local-backup/master-...-...` 看本地修改
  2. 完整:看 [04-backup-faq.md](04-backup-faq.md) 的"本地修改自动备份"章节
- **怎么避免**:在 fork 上改东西用新分支(比如 `my-fix`),不要改 master
- **注意**:`local-backup/` 分支**不自动清理**,需要手动删(详见 [04-backup-faq.md](04-backup-faq.md))

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

### 场景 10: 上游把源码删了只留 README / 说明文件

**这是最危险的情况。** 旧版 workflow 没有防护,会直接同步把 fork 的源码也删光。**新版加了"体积暴减检测"防护**:

| 条件 | 行为 |
|---|---|
| fork 已有实质内容 (≥ 50KB) | 进入检测 |
| upstream 体积 < fork × `SIZE_DROP_THRESHOLD` | **跳过整个 fork**,打 `::error::` 红色警报 |
| upstream 体积 ≥ fork × `SIZE_DROP_THRESHOLD` | 通过,正常 sync |
| fork 太小 (< 50KB,比如新 fork) | 跳过检测 (避免误杀小项目) |

**阈值可调**(`size_drop_threshold` input 或 yml 里的 `DEFAULT_SIZE_DROP_THRESHOLD`):

| 阈值 | 含义 | 误判风险 | 推荐场景 |
|---|---|---|---|
| `0.10` (默认) | 上游只剩 fork 的 10% 触发 | 低 | **大多数人,日常防护** |
| `0.30` | 上游只剩 fork 的 30% 触发 | 中(大重构可能误判) | fork 经常做大手术的项目 |
| `0` | 关闭检测 | 0(但失去防护) | 完全信任 upstream,关掉免打扰 |

**示例输出** (默认 10% 阈值,删源码场景):
```
🛑 危险: 上游体积暴减 (fork=12450KB → upstream=2KB, 上游只剩 fork 的 0.0%,阈值 10%)
   疑似上游删除了源码,只留下 README/说明文件,跳过本次同步
📊 Spider_XHS_cv-cat: 🆕0 ✅0 ❌0 ⏭️1
```

**示例输出** (正常 sync 场景):
```
📏 体积检查通过: fork=12450KB, upstream=15000KB (阈值 10%)
```

**为什么用体积而不是 commit 数或文件数?**
- commit 数 / 文件数变化大,正常重构就可能触发误判
- GitHub repo `.size` 字段 (KB) 是综合指标,正常添加 100 个文件 vs 删 1000 个文件,体积变化明显不同
- 50KB 起步阈值避开新 fork / 小项目
- 10% 比例阈值避开大型重构

**如果你确认 upstream 删源码是合法操作**(比如项目终止 + 公开声明),手动:
1. 进 fork 的 Actions 跑一次本 workflow,**手动触发**,把 SKIPPED 处理掉
2. 或者去 upstream 改回去(重新 push 源码)
3. 或者直接删 fork
4. **或者临时把阈值改成 0**(关闭检测),跑完再改回来
