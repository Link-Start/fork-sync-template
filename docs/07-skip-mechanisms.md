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

## 当前 workflow 行为

这两种跳过机制已经内置在动态版 workflow 中,不需要再手动粘贴代码。

执行顺序:

1. 每个 fork 开始同步前,先读 fork 自己的 `.github/.no-sync`。
2. 如果 `.github/.no-sync` 不存在,再检查配置仓库根目录的 `skip.txt`。
3. 任一命中都会跳过整个 fork,不会创建 backup tag,不会同步任何分支。
4. 跳过结果会写入 Actions log、`summary.jsonl`、issue 汇总、webhook 汇总和 artifact。

注意:`exclude_pattern` / `exclude_repos` / `upstream_owner_filter` 是发现阶段过滤,命中的 fork 不会进入同步列表；`.no-sync` / `skip.txt` 是单 fork 执行阶段跳过,会进入汇总并显示为 `skip`。

---

## 汇总输出会变成这样

```
📊 my-personal-experiment: result=skip 🆕0 ✅0 ❌0 ⏭️1 📦0
```

issue 详情表会显示 `Result=skip` 和对应 reason,例如 `.github/.no-sync` 或 `skip.txt`。

---

## 实操建议

| 场景 | 用哪种 |
|---|---|
| 临时在做实验,怕被 sync 覆盖 | 方法 1 加 `.no-sync`,做完删 |
| 某个 fork 跟 upstream 分道扬镳了(你接手维护) | 方法 1 加 `.no-sync`,写明 "forked and maintained independently" |
| 一批 fork 都不想要(比如 fork 的 fork) | 方法 2 一次性全写进 `skip.txt` |
| 大部分 fork 都要 sync,只有几个不要 | **方法 1** 更省事,每个 fork 自治 |
