# 10. 优化路线图

> **17 项优化全部完成** (2026-06-04),按价值/风险分 4 个 Wave 实施。
> 每个 item 一个 commit,粒度清晰,独立可回退。

---

## 🎉 全部完成

所有 17 项优化已实现并 push 到 main。详见底部 [进度跟踪](#进度跟踪) 表(每项带 commit 链接)。

实施顺序(也是建议 review 顺序):

1. **Wave 1**(高价值低风险,4 项):并发同步 / issue 摘要 / size 豁免 / dry-run
2. **Wave 2**(中价值中风险,4 项):重试退避 / 限流等待 / webhook / 可配置 cron
3. **Wave 3**(大改动,4 项):PR 模式 / 本地 config / JSON 日志 / CSV artifact
4. **Wave 4**(锦上添花,5 项):健康检查 / 状态文件 / drift 检测 / 回滚按钮 / 多 owner

## 📋 Changelog (2026-06-04)

| Commit | Item | 改动 |
|---|---|---|
| `69196d9` | #1 并发同步 | xargs -P 4,N fork 节省一半时间 |
| `a47c615` | #2 issue 摘要 | 跑完自动开/更新 issue 贴汇总 |
| `6798064` | #3 size 豁免 | `size_check_exempt` 白名单,1KB CLI 工具不被误杀 |
| `bd416b8` | #4 dry-run | `dry_run: true` 只看不动 |
| `3da8eee` | #5 重试 | `gh_api_with_retry()` 1s/2s/4s 指数退避 |
| `ce0fa96` | #6 限流 | `check_rate_limit()` 睡到 `X-RateLimit-Reset` |
| `7986094` | #7 webhook | Slack/钉钉/通用 3 种格式,可选失败通知 |
| `4a0901b` | #8 可配置 cron | 3 个 schedule 模板 + 手动 input log |
| `73b02c8` | #9 PR 模式 | `sync_mode: pr` 落后时开 PR 不直接 force |
| `cfe294c` | #10 本地 config | `.github/sync-config.yml` 优先级: input > config > default |
| `ddf2061` | #11 JSON 日志 | `log_event()` 函数,关键节点全打 |
| `9e41b1e` | #12 CSV artifact | events.csv + 30 天 artifact 留档 |
| `c4cc5e3` | #13 health check | 独立 workflow 每天 09:00 UTC 检查 |
| `cc030ce` | #14 状态文件 | per-fork sync-state.json 含 last_result |
| `960c6f6` | #15 drift 检测 | 连续 3 次失败开 `drift-alert` issue |
| `2f4cb56` + `16a6653` | #16 回滚 | 默认保守(建 review 分支)+ 可选强推 (revert 过原版) |
| `1a00100` | #17 多 owner | `target_owners` 逗号分隔,user/org 自动判断 |

---

## 当前已有特性 (5 大防护 + 3 种排除)

| 类别 | 特性 | 配置 |
|---|---|---|
| 排除 | 关键字排除 | `exclude_pattern` (默认 `claude`) |
| 排除 | 指定 fork 名排除 | `exclude_repos` (逗号分隔) |
| 排除 | 上游 owner 过滤 | `upstream_owner_filter` |
| 防护 | 体积暴减检测 (上游删源码防护) | `size_drop_threshold` (默认 0.10) |
| 防护 | 本地修改自动备份 | ahead/diverged 时自动建 `local-backup/{branch}-{时间戳}-{sha7}` |
| 防护 | 默认分支 backup tag | 每次 sync 前建 `backup/{时间戳}-{sha7}`,最多保留 20 个 |

---

## Wave 1: 高价值低风险 (1-2 天,4 项)

### Item 1: 并发同步

- **描述**:fork 循环从串行改 4-8 并发,用 `xargs -P` 或 bash `&` + `wait`
- **价值**:有 N 个 fork 的话节省一半以上时间(API 调用是主要瓶颈)
- **工作量**:中(需要小心子进程输出带回主流程,避免日志错乱)
- **依赖**:无
- **实施要点**:
  - 用 `printf '%s\n' "$FORKS_JSON" | jq -c '.[]' | xargs -P 4 -I {} bash -c '...'`
  - 子进程输出用 `tee` 或 `>>` 追加到 log 文件
  - 错误码用 `wait` 收集

### Item 2: issue 摘要通知

- **描述**:跑完自动开/更新一个 issue 贴汇总(🆕2 ✅15 ❌0 ⏭️1 📦1),免翻 Actions log
- **价值**:中等(用户不用每次都看 log)
- **工作量**:小(主要是格式化文本)
- **依赖**:无
- **实施要点**:
  - 用 `gh api -X POST /repos/{owner}/{repo}/issues` 创建(标题固定,正文带时间戳)
  - 或 `gh api -X PATCH /repos/{owner}/{repo}/issues/{number}` 更新已有 issue
  - 需要 `issues: write` permission(加在 yml 里)
  - 用 `gh issue list --search "in:title sync-report" --json number` 找已有 issue

### Item 3: size 豁免白名单

- **描述**:微型项目(比如 1KB CLI 工具)不会被 size 检查误杀,白名单 fork 名
- **价值**:小(降低误判)
- **工作量**:小
- **依赖**:无
- **实施要点**:
  - 加 input `size_check_exempt` (逗号分隔 fork 名)
  - 阶段 1.5 检测前判断:`if fork 在 exempt 列表 → 跳过检测`
  - 跟 `exclude_repos` 同样处理(逗号转 JSON 数组 + jq 过滤)

### Item 4: dry-run 模式

- **描述**:加 input `dry_run: boolean`,只打印要做什么不真做
- **价值**:高(测试配置时必备)
- **工作量**:小
- **依赖**:无
- **实施要点**:
  - 干跑时所有 `gh api -X POST/PATCH/DELETE` 前面加 `if [ "$DRY_RUN" != "true" ]; then ... fi`
  - 或写个 `gh_api_write()` 函数,内部判断 DRY_RUN
  - 读操作(GET)照常执行,只跳过写操作
  - log 里所有 `🆕` / `✅` / `❌` 前面加 `[DRY-RUN]` 前缀

---

## Wave 2: 中价值中风险 (2-3 天,4 项)

### Item 5: 失败重试 + 指数退避

- **描述**:gh api 偶发 5xx/网络抖动,加重试 3 次 + 指数退避(1s/2s/4s)
- **价值**:中(减少偶发失败)
- **工作量**:中
- **依赖**:Item 4 (dry-run,影响测试)
- **实施要点**:
  - 写个 `gh_api_with_retry()` 函数,封装重试逻辑
  - 检测退出码 + 输出中的 5xx
  - 把所有 `gh api` 替换成 `gh_api_with_retry`
  - 重试用尽后计入 FAILED

### Item 6: API 限流智能等待

- **描述**:403 + `X-RateLimit-Remaining: 0` 时 sleep 到 `X-RateLimit-Reset`
- **价值**:中(避免限流时任务失败)
- **工作量**:中
- **依赖**:Item 5 (重试,延伸)
- **实施要点**:
  - `gh api` 加 `--include` 参数拿响应头
  - 解析 `X-RateLimit-Remaining` 和 `X-RateLimit-Reset`(epoch 秒)
  - sleep 到 reset 时间 + 1s buffer
  - 写操作时检查(读操作不严格)

### Item 7: Slack/钉钉 webhook

- **描述**:失败时主动推 webhook URL,成功时静默
- **价值**:中(即时知道出问题)
- **工作量**:中
- **依赖**:无
- **实施要点**:
  - 加 input `webhook_url`(也支持 repo secret `SYNC_WEBHOOK_URL`)
  - 失败时 POST 简单 JSON payload(Slack 兼容格式或钉钉)
  - 用 `curl -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"`
  - 不要在 payload 里泄露敏感信息(fork 名可以,token 不行)

### Item 8: 可配置 cron 频率

- **描述**:默认 `0 2 * * *`,支持每天/每周/每月
- **价值**:中(灵活)
- **工作量**:小
- **依赖**:无
- **实施要点**:
  - cron 在 workflow yml 里不能 input 化(只能写在 yml)
  - 方案:加 4 个 schedule 触发器(每天/每周一/每月1号/每小时),用 input `frequency` 在 step 里判断要不要真跑
  - 或用 cron 表达式 input 化(通过 `repository_dispatch` 触发 + 外部调度器,复杂)

---

## Wave 3: 大改动 (3-5 天,4 项)

### Item 10: 本地配置 .github/sync-config.yml

- **描述**:workflow 读取 fork 自带 config,不用改 workflow 文件
- **价值**:高(用户改 fork 加 config 就行,不用 fork 配置仓库)
- **工作量**:大
- **依赖**:无
- **实施要点**:
  - 加 step 读取 `$MY_OWNER/$FORK_REPO/contents/.github/sync-config.yml`
  - 支持 YAML 解析(`yq` 或 `python -c "import yaml; ..."`)
  - 支持配置项:`exclude_repos` / `size_check_exempt` / `sync_mode` / `webhook_url` / `cron_frequency`
  - workflow 里用 config 覆盖 input/env 默认值
  - config 不存在时不报错,继续用默认

### Item 11: 结构化 JSON 日志

- **描述**:每个 fork 输出 JSON 格式,方便后续处理
- **价值**:中(给 Item 9/12 提供基础)
- **工作量**:中
- **依赖**:无
- **实施要点**:
  - 每个 fork 处理完 echo `{"name": "xxx", "new": 2, "synced": 15, "failed": 0, "skipped": 1, "local_backup": 0, "ts": "..."}`
  - 用 `tee -a sync-result.jsonl` 存到 workspace
  - 也输出给人看的 emoji 格式(双管齐下)

### Item 9: PR 模式同步

- **描述**:不直接 PATCH,改开 `sync/{branch}` PR 让用户手动 merge
- **价值**:高(不破坏本地提交,可选)
- **工作量**:大
- **依赖**:Item 10 (config 控制 sync_mode)
- **实施要点**:
  - 加 input `sync_mode: direct|pr`(默认 direct 保持兼容)
  - pr 模式:不 PATCH,改用 `gh api -X POST .../pulls` 开 `sync/{branch}` PR
  - PR base = `branch`, head = upstream commit
  - 用 upstream SHA 作为 head ref(在 fork 里临时建一个 ref)
  - PR body 写明:`🤖 自动 sync,请 review 后 merge`

### Item 12: CSV 报告 artifacts

- **描述**:用 JSON 日志(Item 11)转 CSV,actions/upload-artifact 上传
- **价值**:中(留档)
- **工作量**:小
- **依赖**:Item 11 (JSON 日志)
- **实施要点**:
  - `jq -r '.[] | [.name, .new, .synced, .failed, .skipped, .local_backup, .ts] | @csv' sync-result.jsonl`
  - 加 header
  - `actions/upload-artifact@v4` 上传,保留 30 天

---

## Wave 4: 锦上添花 (按需,4+ 项)

### Item 13: health check endpoint

- **描述**:加个独立 workflow 定期跑测试,失败开 issue 告警
- **价值**:中(监控)
- **工作量**:中
- **依赖**:无
- **实施要点**:
  - 新建 `.github/workflows/health-check.yml`
  - 每天跑一次,测试 sync 核心功能(选一个测试 fork 跑 dry-run)
  - 失败开 issue 告警
  - 跟主 workflow 解耦

### Item 14: per-fork 状态文件 .sync-state.json

- **描述**:在每个 fork 存一个 `.sync-state.json` 记录元数据
- **价值**:小
- **工作量**:小
- **依赖**:无
- **实施要点**:
  - sync 成功后写入 `{"last_sync": "2026-06-03T...", "last_sha": "abc1234", "result": "ok"}`
  - 下次 sync 前读取,如果最近 1 小时内刚 sync 过可以 skip
  - 注意:这文件本身会被 PATCH --force 覆盖,要确保写在 sync 之后

### Item 15: drift 检测

- **描述**:连续 3 次失败自动开 issue 告警(可能 fork 或 upstream 出问题)
- **价值**:中
- **工作量**:小
- **依赖**:Item 14 (state 文件记录失败次数)
- **实施要点**:
  - 读 `.sync-state.json` 的 `consecutive_failures` 字段
  - >= 3 时开 issue 告警
  - 成功后重置计数

### Item 16: 回滚按钮

- **描述**:用 `workflow_call` 做一个回滚 workflow,参数填 backup tag 名
- **价值**:中(快速恢复)
- **工作量**:中
- **依赖**:无
- **实施要点**:
  - 新建 `.github/workflows/rollback.yml` 用 `workflow_call`
  - input: `fork_repo` + `tag_name`
  - 调用 `git/refs` 把分支 reset 到 tag SHA
  - 跟主 workflow 互不干扰

### Item 17: 多 owner 支持

- **描述**:不只同步自己账号,支持同步指定 team/org 下的 fork
- **价值**:中(团队场景)
- **工作量**:中
- **依赖**:无
- **实施要点**:
  - 当前 `gh api user/repos` 改成 `gh api orgs/{org}/repos` 或 `gh api users/{user}/repos`
  - 加 input `target_owners: comma-separated-list`
  - 遍历每个 owner,合并 forks 列表

---

## 进度跟踪

| Wave | Item | 状态 | Commit |
|---|---|---|---|
| 文档 | 10-roadmap.md | ✅ 完成 | - |
| Wave 1 | 1. 并发同步 | ✅ 完成 | [`69196d9`](https://github.com/Link-Start/fork-sync-template/commit/69196d9) |
| Wave 1 | 2. issue 摘要 | ✅ 完成 | [`a47c615`](https://github.com/Link-Start/fork-sync-template/commit/a47c615) |
| Wave 1 | 3. size 豁免 | ✅ 完成 | [`6798064`](https://github.com/Link-Start/fork-sync-template/commit/6798064) |
| Wave 1 | 4. dry-run | ✅ 完成 | [`bd416b8`](https://github.com/Link-Start/fork-sync-template/commit/bd416b8) |
| Wave 2 | 5. 重试 | ✅ 完成 | [`3da8eee`](https://github.com/Link-Start/fork-sync-template/commit/3da8eee) |
| Wave 2 | 6. 限流 | ✅ 完成 | [`ce0fa96`](https://github.com/Link-Start/fork-sync-template/commit/ce0fa96) |
| Wave 2 | 7. webhook | ✅ 完成 | [`7986094`](https://github.com/Link-Start/fork-sync-template/commit/7986094) |
| Wave 2 | 8. 可配置 cron | ✅ 完成 | [`4a0901b`](https://github.com/Link-Start/fork-sync-template/commit/4a0901b) |
| Wave 3 | 9. PR 模式 | ✅ 完成 | [`73b02c8`](https://github.com/Link-Start/fork-sync-template/commit/73b02c8) |
| Wave 3 | 10. 本地配置 | ✅ 完成 | [`cfe294c`](https://github.com/Link-Start/fork-sync-template/commit/cfe294c) |
| Wave 3 | 11. JSON 日志 | ✅ 完成 | [`ddf2061`](https://github.com/Link-Start/fork-sync-template/commit/ddf2061) |
| Wave 3 | 12. CSV 报告 | ✅ 完成 | [`9e41b1e`](https://github.com/Link-Start/fork-sync-template/commit/9e41b1e) |
| Wave 4 | 13. health check | ✅ 完成 | [`c4cc5e3`](https://github.com/Link-Start/fork-sync-template/commit/c4cc5e3) |
| Wave 4 | 14. 状态文件 | ✅ 完成 | [`cc030ce`](https://github.com/Link-Start/fork-sync-template/commit/cc030ce) |
| Wave 4 | 15. drift 检测 | ✅ 完成 | [`960c6f6`](https://github.com/Link-Start/fork-sync-template/commit/960c6f6) |
| Wave 4 | 16. 回滚按钮 | ✅ 完成 (revert 后重做) | [`2f4cb56`](https://github.com/Link-Start/fork-sync-template/commit/2f4cb56) + [`16a6653`](https://github.com/Link-Start/fork-sync-template/commit/16a6653) |
| Wave 4 | 17. 多 owner | ✅ 完成 | [`1a00100`](https://github.com/Link-Start/fork-sync-template/commit/1a00100) |

---

## 未来可加 (按需,未排期)

如果以后想再加东西,以下是一些候选方向:

- **per-fork 失败重试** — 单个 fork 失败自动重试 N 次 (目前重试是 per-API-call,不是 per-fork)
- **sync dashboard** — 写个静态 HTML page 展示 sync 状态历史
- **multi-repo 模板支持** — 一个 workflow 跑多个配置 (现在是单 repo)
- **Slack interactive button** — 失败 issue 加 "立即回滚" / "跳过这次" 按钮
- **更细粒度 webhook** — 按成功/失败/fail 数 阈值发不同级别通知

**怎么贡献**:在 GitHub issues 提,讨论后加进这份路线图。
