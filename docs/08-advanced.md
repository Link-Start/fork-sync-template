# 08. 高级定制

## 加网络重试 (推荐)

项目已经把常用方法沉淀到 `scripts/` 下,便于查看和复用:

| 文件 | 用途 |
|---|---|
| `scripts/read-config.sh` | 读取 `.github/sync-config.yml`,把配置覆盖写入后续 workflow 环境 |
| `scripts/discover-forks.sh` | 动态发现 fork,支持 `only_repos` 单仓库测试、多 owner、排除列表和 upstream 元数据补齐 |
| `scripts/disable-fork-workflows.sh` | 可选同步前禁用目标 fork 的 GitHub Actions workflows,支持 dry-run 和白名单 |
| `scripts/sync-each-fork.sh` | 并发同步编排、结构化事件日志、CSV/artifact 状态生成 |
| `scripts/fork-worker.sh` | 单个 fork 的分支同步、备份、discard/merge、保护性 skip 主流程 |
| `scripts/detect-drift.sh` | 连续失败 drift 检测、告警 issue、`workflow-state` 状态分支写回 |
| `scripts/post-issue-summary.sh` | 汇总 `summary.jsonl` 并创建/更新固定同步报告 issue |
| `scripts/send-webhook.sh` | 基于同步汇总发送 Slack / 钉钉 / generic webhook 通知 |
| `scripts/github-api.sh` | `gh api` 重试、错误字段解析、错误 hint、upstream 仓库/分支探测 |
| `scripts/git-cli.sh` | 临时 git 仓库初始化、fetch ref、merge-base、patch-id 签名比较 |
| `scripts/common.sh` | 通用结构化事件日志函数 |

workflow 会 checkout 当前配置仓库并执行 `scripts/` 下的脚本;目标 fork 仍然不 checkout、不 git push。`scripts/` 是运行时逻辑和本地排障共用的实现。

本地探测 upstream 可访问性示例:

```bash
source scripts/github-api.sh
probe_upstream_repository Jawaz-Keyzor DarkGPT
probe_upstream_branches Jawaz-Keyzor DarkGPT
```

把 `gh api` 调用包一层重试函数:

```bash
gh_api_with_retry() {
  local max=3
  local i=1
  while [ $i -le $max ]; do
    if "$@"; then return 0; fi
    echo "  ⚠️ API 失败,重试 $i/$max"
    sleep $((i * 5))
    i=$((i+1))
  done
  return 1
}

# 用法 (替换所有 gh api 调用)
UPSTREAM_DEFAULT=$(gh_api_with_retry gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO" --jq '.default_branch')
```

## 同步失败发通知 (邮件 / 钉钉 / Slack)

在 yml 末尾加:

```yaml
      - name: Notify on failure
        if: failure()
        run: |
          curl -X POST "https://hooks.example.com/notify" \
            -H "Content-Type: application/json" \
            -d '{"text": "Fork sync 失败,看 https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}"}'
```

## 只同步一次,不每天跑

把 `schedule` 段删掉,只留 `workflow_dispatch`,需要时手动触发。

## 同步前禁用 fork 自己的 workflows

如果目标 fork 只用来跟 upstream 保持镜像,一般不需要 fork 里的 `schedule`、`push`、docs 或 release workflow 继续自动运行。否则这些 workflow 可能在 fork 里自动提交文档时间戳、构建产物或版本文件,让 fork 相对 upstream 产生本地提交;下次同步时就会出现 `ahead` / `diverged`,并触发 `local-backup/*` 保护分支。

长期配置示例:

```yaml
disable_fork_workflows: true
disable_fork_workflows_repos: "all"
disable_fork_workflows_keep_patterns: "ci.yml,release*"
```

关键行为:

- 默认关闭,不影响通用用户的 CI / release / docs / deploy。
- `disable_fork_workflows_repos: "all"` 表示本次发现并准备同步的全部 fork;也可以填 `repo-a,owner/repo-b` 精确控制。
- `disable_fork_workflows_keep_patterns` 是白名单 glob,匹配 workflow 名称、`.github/workflows/*.yml` 路径或文件名。
- `workflow_disable_ttl_days` (默认 14):已全量禁用的 fork 在此天数内跳过重新探测 (缓存命中,省 API 配额),避免每次 run 都全量列 455 个 fork 的 workflows 打爆限流;超过 TTL 强制重新探测,防止 fork 端手动调整策略未被感知。
- 新 fork 首次出现即强制探测,不受 TTL 限制;修改 `disable_fork_workflows_*` 配置也会强制全部重新探测。
- 探测状态 (每个 fork 的 `last_probed_at` / `all_disabled` / workflow 统计) 存配置仓库 `workflow-state` 分支的 `workflow-disable-state.json`,由每次 run 末尾写回。
- workflow 会在 `Discover forks` 后、`Sync each fork` 前执行禁用动作,让 fork 内部自动化先停下来再同步。
- 如果当前配置仓库本身也是 fork,`all` 不会默认禁用当前配置仓库自身;确实要禁用时需要显式写仓库名。
- 全局 `dry_run: true` 时只列出会禁用的 workflow,不会调用 disable API。
- 禁用失败会写入事件日志和 CSV,但不阻塞后续同步;这样权限不够时仍能完成普通 fork sync。

权限要求:普通同步只需要目标 fork `Contents: Read and write`;启用这个功能还需要 PAT 对目标 fork 有 `Actions: Read and write`。workflow 文件本身也声明了 `actions: write`,用于当前 token 有权限时管理 workflows。

单仓库 dry-run 示例:

```yaml
only_repos: "lanhu-mcp_dsphper"
dry_run: true
disable_fork_workflows_repos: "lanhu-mcp_dsphper"
disable_fork_workflows_keep_patterns: ""
```

## 三阶段模型 + 分批同步,避免打爆 API 配额

单次全量同步 455 个 fork 需要约 5000 次 API 调用,恰好顶满 GitHub 每小时配额 (5000),稍有波动就撞限流。为此整个同步拆成三阶段,**检测只针对"有更新的 fork"做 compare,同步只处理这批 fork**,再配合配额护栏自动分批:

```yaml
# 阶段2 每批同步的 fork 数 (约 10 次 API 调用/个,批次内不超限)
sync_batch_size: 15
# 剩余配额安全线:每批跑完检查剩余配额,低于此值提前结束本 run
# 剩余批次存注册表,下次 run 自动补上 (幂等)
sync_rate_safe_threshold: 300
# 阶段1 检测更新时每批检测的 fork 数,批间也查配额
compare_batch_size: 100
# 每 N 天全量重检一次可同步/不可同步列表 (默认 14)
# 全量重检才 discover 所有 fork + 逐个 enrich;其余每天只轻量 diff
full_check_interval_days: 14
```

- 每批跑完用 `rate_limit` 端点 (不消耗配额) 检查剩余量,低于 `sync_rate_safe_threshold` 就优雅结束,**不失败、不 sleep 跨窗口**。
- 批次和失败状态都持久化在 `workflow-state` 分支的 `fork-registry.json` (syncable / unsyncable / new / retry_failed / pending_batches),跨 run 断点续传,不需要每轮全量重跑。
- 不跨窗口等待的原因:单 run 睡到下一小时窗口会把单次 Actions 运行拖到 5-6 小时,免费额度 (2000 分钟/月) 撑不住;每天三次短 run (8/9/20 点)、每批不超限更划算。
- 新 fork 自动排到批次尾部 (阶段1 标 `is_new`),首批同步旧 fork。
- 配额紧张时调小 `sync_batch_size` / `compare_batch_size`,调大 `sync_rate_safe_threshold` / `full_check_interval_days`。

## 同步前先跑测试

加一个 `test` job 在 `sync` job 之前,`sync` 加 `needs: test`:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo "跑测试..."
  sync:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - ...
```

## Reusable workflow (推荐架构)

如果你有多个 fork 用同样的 sync 逻辑,做成 reusable workflow 一份逻辑多处复用。

详见 [06-multi-fork.md](06-multi-fork.md) 的 "用 reusable workflow 复用 sync 逻辑" 节。

## Skip 机制整合

如果你想 fork 不参与 sync(临时实验 / 永久不维护 / 等等),详见 [07-skip-mechanisms.md](07-skip-mechanisms.md)。

---

## 参考链接

- [GitHub REST API - Branches](https://docs.github.com/en/rest/branches/branches)
- [GitHub REST API - Git refs](https://docs.github.com/en/rest/git/refs)
- [GitHub REST API - Commits (compare)](https://docs.github.com/en/rest/commits/commits#compare-two-commits)
- [GitHub Actions 定时任务](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#schedule)
- [GitHub Actions 权限](https://docs.github.com/en/actions/security-guides/automatic-token-authentication)
- [`gh` CLI 文档](https://cli.github.com/manual/)
- [Reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [Configuration repository 模式](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)

---

## License

MIT - 自由使用,自由修改。
