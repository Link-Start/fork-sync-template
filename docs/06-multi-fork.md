# 06. 多 fork 一次性同步 (matrix vs 动态发现)

## 为什么 upstream_repo 必须每个 fork 各写一个

它本身就是 fork 专属的:
- 你 fork 的是 `cv-cat/Spider_XHS`,那 `upstream_repo` 就是 `Spider_XHS`
- 你 fork 的 `cv-cat/BilibiliApis`,`upstream_repo` 就是 `BilibiliApis`

**这没法通用**。所以**多 fork 同步**有两种风格,看你要不要维护列表。

---

## 风格 1: 静态 matrix(写死 8 个 fork)

```yaml
matrix:
  fork:
    - { fork_repo: Spider_XHS_cv-cat,     upstream_repo: Spider_XHS }
    - { fork_repo: OpenFeiShuApis-cv-cat, upstream_repo: OpenFeiShuApis }
    - { fork_repo: WechatOAApis-cv-cat,   upstream_repo: WechatOAApis }
    - { fork_repo: XhsSkills-cv-cat,      upstream_repo: XhsSkills }
    - { fork_repo: TaoBaoApis-cv-cat,     upstream_repo: TaoBaoApis }
    - { fork_repo: BilibiliApis-cv-cat,   upstream_repo: BilibiliApis }
    - { fork_repo: ZhihuApis-cv-cat,      upstream_repo: ZhihuApis }
    - { fork_repo: XianYuApis-cv-cat,     upstream_repo: XianYuApis }
```

**特点**:
- 8 行 YAML 搞定 8 个 fork,改动一目了然
- 加新 fork 就在 matrix 加一行
- 删 fork 就在 matrix 删一行
- 缺点:得手动维护列表

---

## 风格 2: 动态发现(零配置,自动适配)

**完全不用写 fork 列表**,workflow 启动时自己问 GitHub API "我有几个 fork",然后逐个同步:

```yaml
name: Sync All My Forks (Auto Discover)

on:
  schedule:
    - cron: '0 2 * * *'
  workflow_dispatch:
    inputs:
      upstream_owner_filter:
        description: '只同步这个 owner 旗下的 fork (留空 = 同步所有 fork)'
        required: false
        default: ''

permissions:
  contents: write

jobs:
  sync-all:
    runs-on: ubuntu-latest
    steps:
      - name: Discover forks
        id: discover
        env:
          FILTER: ${{ inputs.upstream_owner_filter }}
        run: |
          set -e
          
          # 列出我的所有 fork,过滤出有 parent (即没被删) 的
          FORKS=$(gh api 'user/repos?per_page=100&type=owner&sort=updated' \
                  --jq '[.[] | select(.fork == true and .parent != null) | {
                    name: .name,
                    parent_name: .parent.name,
                    parent_owner: .parent.owner.login,
                    parent_default_branch: .parent.default_branch
                  }]')
          
          # 如果指定了 filter,只保留该 owner 旗下的 fork
          if [ -n "$FILTER" ]; then
            FORKS=$(echo "$FORKS" | jq --arg f "$FILTER" '[.[] | select(.parent_owner == $f)]')
          fi
          
          COUNT=$(echo "$FORKS" | jq length)
          echo "forks<<EOF" >> "$GITHUB_OUTPUT"
          echo "$FORKS" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"
          
          echo "🔍 发现 $COUNT 个 fork 待同步"
          echo "$FORKS" | jq -r '.[] | "  - \(.name) ← \(.parent_owner)/\(.parent_name)"'

      - name: Sync each fork
        env:
          FORKS: ${{ steps.discover.outputs.forks }}
          MY_OWNER: Link-Start
        run: |
          set -e
          echo "$FORKS" | jq -c '.[]' | while read -r fork; do
            FORK_REPO=$(echo "$fork" | jq -r '.name')
            UPSTREAM_OWNER=$(echo "$fork" | jq -r '.parent_owner')
            UPSTREAM_REPO=$(echo "$fork" | jq -r '.parent_name')
            UPSTREAM_BRANCH=$(echo "$fork" | jq -r '.parent_default_branch')
            
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🔄 $FORK_REPO ← $UPSTREAM_OWNER/$UPSTREAM_REPO"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # ===== 下面是核心 sync 逻辑 (跟 sync-dynamic.yml 一样) =====
            # 因为篇幅这里省略,实际部署时把 sync-dynamic.yml 阶段 1-5 的代码全搬过来
            # 把所有 env 变量替换为 $UPSTREAM_OWNER / $UPSTREAM_REPO / $MY_OWNER / $FORK_REPO
            
            # 阶段 1: 上游存活检查
            UPSTREAM_DEFAULT=$UPSTREAM_BRANCH  # 直接用 parent 的 default_branch
            
            # 阶段 2: 备份 fork
            FORK_DEFAULT_SHA=$(gh api "repos/$MY_OWNER/$FORK_REPO/git/ref/heads/$UPSTREAM_DEFAULT" \
                               --jq '.object.sha' 2>/dev/null || echo "")
            if [ -n "$FORK_DEFAULT_SHA" ]; then
              BACKUP_TAG="backup/$(date +%Y%m%d-%H%M%S)-${FORK_DEFAULT_SHA:0:7}"
              gh api -X POST "repos/$MY_OWNER/$FORK_REPO/git/refs" \
                -f ref="refs/tags/$BACKUP_TAG" \
                -f sha="$FORK_DEFAULT_SHA" >/dev/null 2>&1 \
                && echo "💾 备份: $BACKUP_TAG"
            fi
            
            # 阶段 3: 同步 (把 sync-dynamic.yml 的 for 循环代码搬过来,替换 env 即可)
            # ... 略 ...
            
            # 阶段 5: 汇总
            echo "✅ $FORK_REPO 同步完成"
          done
```

**特点**:
- **零配置**:不用写 fork 列表,workflow 自己查
- **新增 fork 自动同步**:你新 fork 一个仓库,明天就自动被 sync
- **删除 fork 自动跳过**:你删了某个 fork,workflow 跑时就看不到了
- **filter 可选**:手动触发时可以填 `cv-cat` 只同步 cv-cat 旗下的;不填就同步所有 fork
- 缺点:yml 比较长(因为把核心逻辑复制过来了),但复用性最强

---

## 风格对比

| 维度 | 风格 1 静态 matrix | 风格 2 动态发现 |
|---|---|---|
| 配置工作量 | 8 行 matrix 写死 | 0 行,自动查 |
| 加新 fork | 手动加 matrix 项 | 自动包含 |
| 删 fork | 手动删 matrix 项 | 自动跳过 |
| 灵活性 | 中(只列指定的) | 高(自动覆盖所有) |
| yml 长度 | 短 | 长(核心逻辑内联) |
| 调试难度 | 易(matrix 一目了然) | 中(要先理解 API 发现) |
| 跑得快慢 | 一样 | 一样(都是 N 个 gh api) |
| 适合场景 | fork 数量固定 | fork 数量会变 |

---

## 我的推荐

| 场景 | 推荐 |
|---|---|
| fork 数量固定(就 8 个) | 风格 1 静态 matrix,简单清晰 |
| 你会持续 fork 新仓库 | 风格 2 动态发现,一劳永逸 |
| 想同步**所有** fork(包括非 cv-cat 的 50+ 个) | 风格 2 动态发现 |

考虑到名下 fork 多,**风格 2 更适合**——不用维护列表,新 fork 进来自动覆盖,旧 fork 删了自动跳过。

---

## 用 reusable workflow 复用 sync 逻辑

如果同时用风格 1 + 风格 2 yml 太长,可以把核心逻辑抽成 reusable workflow,各风格只引用它。

**步骤 1: 在配置仓库建一个 reusable workflow**

```yaml
# .github/workflows/sync-reusable.yml
name: Sync Upstream (Reusable)

on:
  workflow_call:
    inputs:
      upstream_owner:
        required: true
        type: string
      upstream_repo:
        required: true
        type: string
      fork_owner:
        required: true
        type: string
      fork_repo:
        required: true
        type: string

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - name: Sync
        env:
          UPSTREAM_OWNER: ${{ inputs.upstream_owner }}
          UPSTREAM_REPO: ${{ inputs.upstream_repo }}
          FORK_OWNER: ${{ inputs.fork_owner }}
          FORK_REPO: ${{ inputs.fork_repo }}
        run: |
          # 把 sync-dynamic.yml 阶段 1-5 的代码全粘这里
```

**步骤 2: 静态 matrix 风格 yml 用 `uses:` 引用**

```yaml
jobs:
  sync:
    strategy:
      matrix:
        fork:
          - { fork_repo: Spider_XHS_cv-cat, upstream_repo: Spider_XHS }
          # ...
    steps:
      - uses: ./.github/workflows/sync-reusable.yml
        with:
          upstream_owner: cv-cat
          upstream_repo: ${{ matrix.fork.upstream_repo }}
          fork_owner: Link-Start
          fork_repo: ${{ matrix.fork.fork_repo }}
```

**步骤 3: 动态发现风格 yml 同样用 `uses:` 引用**

```yaml
steps:
  - name: Discover forks
    # ... (同风格 2 的 discover step)
  - name: Sync each fork
    uses: ./.github/workflows/sync-reusable.yml
    with:
      upstream_owner: ${{ env.DISCOVERED_UPSTREAM_OWNER }}
      upstream_repo: ${{ env.DISCOVERED_UPSTREAM_REPO }}
      fork_owner: ${{ env.MY_OWNER }}
      fork_repo: ${{ env.DISCOVERED_FORK_REPO }}
```

**好处**:核心逻辑写一份,多处复用。
