# 07. 跳过机制 (per-fork + 集中)

**有些 fork 我不想自动同步,怎么办?**

两种机制可以混用,**任一命中就跳过**。

---

## 方法 1 (推荐): fork 自带 `.github/.no-sync`

在要跳过的 fork 里加一个文件 `.github/.no-sync`,内容随便写(可以是理由)。

### 启用跳过

```bash
# 替换 <fork-name> 为实际的 fork 名
gh api -X PUT repos/Link-Start/<fork-name>/contents/.github/.no-sync \
  -f message="ci: opt out of auto sync" \
  -f content="$(echo -n '在此 fork 手动维护不同步' | base64 | tr -d '\n')"
```

文件内容随便写:
- 空 (纯标记)
- 写理由(workflow 会读这一行作为跳过原因打日志)

### 取消跳过 (恢复同步)

```bash
# 拿 fork 里 .no-sync 文件的 SHA
SHA=$(gh api repos/Link-Start/<fork-name>/contents/.github/.no-sync --jq '.sha')
# 删掉
gh api -X DELETE repos/Link-Start/<fork-name>/contents/.github/.no-sync \
  -f message="ci: re-enable auto sync" \
  -f sha="$SHA"
```

### 优点

- 决定权在 fork 自己,哪个 fork 要跳过去那个 fork 加文件,不动其他
- 一眼能看到这个 fork 被跳过了(文件就在那)
- 临时跳过(做完实验就删 `.no-sync`)、永久跳过(留着)都行

---

## 方法 2 (可选,集中管理): config 仓库 `skip.txt`

在配置仓库根目录加 `skip.txt`,每行一个 fork 名:

```bash
gh api -X PUT repos/Link-Start/<配置仓库>/contents/skip.txt \
  -f message="ci: add skip list" \
  -f content="$(echo -n 'my-personal-experiment
legacy-fork-dont-touch
# 这是注释行,开头 # 会被忽略
another-fork-to-skip' | base64 | tr -d '\n')"
```

要恢复某个 fork 的同步,从 `skip.txt` 删掉那一行就行。

### 优点 / 缺点

- ✅ 在配置仓库一处管所有 fork 的跳过状态
- ❌ 不像方法 1 那么"自治",得切到配置仓库改

---

## 集成到 yml 的代码

加在同步循环**开头**(原 sync-dynamic.yml 的阶段 3.0 位置):

```bash
# ---------- 阶段 3.0: 跳过检查 (新加的) ----------
SKIPPED=()  # 加在脚本顶部的变量初始化里

# 方法 1: fork 自带 .github/.no-sync 文件
SKIP_REASON=$(gh api "repos/$MY_OWNER/$FORK_REPO/contents/.github/.no-sync" \
              --jq -r '.content // ""' 2>/dev/null \
              | base64 -d 2>/dev/null | head -c 100 || echo "")

# 方法 2: config 仓库的 skip.txt
SKIP_LIST=$(gh api "repos/$GITHUB_REPOSITORY/contents/skip.txt" \
            --jq -r '.content // ""' 2>/dev/null \
            | base64 -d 2>/dev/null | grep -v '^#' | grep -v '^$' || echo "")

if [ -n "$SKIP_REASON" ]; then
  echo "⏭️ 跳过 $FORK_REPO (fork 自带 .no-sync: $SKIP_REASON)"
  SKIPPED+=("$FORK_REPO")
  continue
fi

if echo "$SKIP_LIST" | grep -qxF "$FORK_REPO"; then
  echo "⏭️ 跳过 $FORK_REPO (在 config 仓库 skip.txt 中)"
  SKIPPED+=("$FORK_REPO")
  continue
fi

# 阶段 3.1 开始就是原来的 upstream SHA 获取逻辑
UPSTREAM_SHA=$(gh api "repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/git/ref/heads/$branch" \
               --jq '.object.sha' 2>/dev/null || echo "")
```

汇总阶段 5 也要加一行:

```bash
echo "  ⏭️ 跳过:     ${#SKIPPED[@]}"
[ ${#SKIPPED[@]} -gt 0 ] && echo "     $(printf '%s ' "${SKIPPED[@]}")"
```

---

## 汇总输出会变成这样

```
📊 同步结果
  🆕 新建分支: 0
  ✅ 同步成功: 7
  ⏭️ 跳过:     1
     my-personal-experiment
  ❌ 失败:     0
```

---

## 实操建议

| 场景 | 用哪种 |
|---|---|
| 临时在做实验,怕被 sync 覆盖 | 方法 1 加 `.no-sync`,做完删 |
| 某个 fork 跟 upstream 分道扬镳了(你接手维护) | 方法 1 加 `.no-sync`,写明 "forked and maintained independently" |
| 一批 fork 都不想要(比如 fork 的 fork) | 方法 2 一次性全写进 `skip.txt` |
| 大部分 fork 都要 sync,只有几个不要 | **方法 1** 更省事,每个 fork 自治 |
