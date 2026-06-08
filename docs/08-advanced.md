# 08. 高级定制

## 加网络重试 (推荐)

项目已经把常用方法沉淀到 `scripts/` 下,便于查看和复用:

| 文件 | 用途 |
|---|---|
| `scripts/github-api.sh` | `gh api` 重试、错误字段解析、错误 hint、upstream 仓库/分支探测 |
| `scripts/git-cli.sh` | 临时 git 仓库初始化、fetch ref、merge-base、patch-id 签名比较 |

workflow 仍然保持 no-checkout 架构,运行时会内联必要函数;`scripts/` 是同逻辑的可读参考实现,适合本地排障和后续抽取复用。

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
