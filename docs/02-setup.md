# 02. 一次性配置 + 触发机制

## 一次性配置 (4 步)

### 步骤 1: 创建配置仓库并推入 yml

**不要**把 yml 推到主 fork(见 [01-architecture.md](01-architecture.md))。先建一个独立配置仓库。

**方式 A: 命令行(推荐)**

```bash
# 1.1 建配置仓库 (public / private 都可以)
gh repo create <你的用户名>/<fork-name>-sync \
  --public \
  --description "GitHub Actions 配置:自动同步 <fork-name> ↔ <upstream>" \
  --add-readme

# 1.2 clone 到本地临时目录
TMP=$(mktemp -d) && cd "$TMP"
gh repo clone <你的用户名>/<fork-name>-sync sync-config
cd sync-config
rm -f README.md
mkdir -p .github/workflows

# 1.3 拷贝 yml
cp /path/to/fork-sync-template/.github/workflows/sync-dynamic.yml .github/workflows/

# 1.4 commit + push
git add .
git commit -m "ci: add upstream sync workflow"
git push
cd / && rm -rf "$TMP"
```

**方式 B: GitHub 网页**

1. 先建空仓库:`https://github.com/new`,名字填 `<fork-name>-sync`,**不要**勾选 "Add a README file"
2. 仓库建好后,在仓库页点 "Add file" → "Create new file"
3. 路径填:`.github/workflows/sync-dynamic.yml`
4. 内容粘贴 `sync-dynamic.yml` 全部
5. 点 "Commit new file"

---

### 步骤 2: 修改仓库坐标

打开 `<fork-name>-sync` 仓库的 `.github/workflows/sync-dynamic.yml`,找到这段:

```yaml
env:
  UPSTREAM_OWNER: cv-cat           # ← 改成上游的作者/组织
  UPSTREAM_REPO: Spider_XHS        # ← 改成上游的仓库名
  FORK_OWNER: Link-Start           # ← 改成你 fork 后的账号
  FORK_REPO: Spider_XHS_cv-cat     # ← 改成你 fork 后的仓库名
```

**怎么找这些值**:
- 浏览器打开上游仓库,URL 是 `https://github.com/<owner>/<repo>`,owner 和 repo 就是前两
- fork 仓库同理

---

### 步骤 3: 给配置仓库开 workflow 写权限 ⚠️ 重要

注意是**配置仓库**(`<fork-name>-sync`)的 Settings,不是主 fork。

1. 打开 **配置仓库** 的 `Settings` 标签
2. 左侧菜单点 `Actions` → `General`
3. 滚到 "Workflow permissions" 部分
4. 选 **`Read and write permissions`** (不是默认的 Read only)
5. 点 Save

**为什么**:workflow 要 `PATCH`/`POST` 主 fork 的 `git/refs`,需要 write 权限。否则全部 403。

---

### 步骤 4: 手动触发一次验证

1. 打开**配置仓库**的 `Actions` 标签
2. 左侧选 "Sync Upstream via API"
3. 右侧点 "Run workflow" → 绿色按钮
4. 等 10-20 秒,展开运行记录看日志
5. **预期成功日志长这样**:
   ```
   🔍 上游默认分支: master
   💾 备份当前 fork: backup/20260602-153045-abc1234 → abc1234
   ━━━ 同步分支: master ━━━
   ⏪ 落后 47 → merge-upstream 快进成功
   📊 同步结果
     🆕 新建分支: 0
     ✅ 同步成功: 1
     ❌ 失败:     0
   ```

---

## 触发机制

### 自动定时

```yaml
schedule:
  - cron: '0 2 * * *'
```

- 每天 **UTC 02:00** 跑 (即 **北京时间 10:00**)
- cron 格式: `分 时 日 月 周`,**注意是 UTC 时区**
- GitHub 定时任务有 5-30 分钟误差,不一定精确到分

**改频率速查**:

| 你想要 | cron 表达式 | 说明 |
|---|---|---|
| 每 6 小时 | `0 */6 * * *` | 0/6/12/18 点 |
| 每 12 小时 | `0 */12 * * *` | 0/12 点 |
| 每周一次 (周一) | `0 2 * * 1` | UTC 周一 2 点 |
| 每月 1 号 | `0 2 1 * *` | UTC 每月 1 号 2 点 |
| 每天 2 次 (0点,12点) | `0 0,12 * * *` | UTC 0/12 点 |

**注意**: GitHub 免费版 fork 仓库的定时任务可能被禁用,需要先去 Actions 标签页手动 enable 一次 (有黄色提示)。**用独立配置仓库(非 fork)就没有这个限制**。

### 手动触发

```yaml
workflow_dispatch:
```

打开 Actions 标签 → 选 workflow → "Run workflow" 按钮。**推荐第一次配置完手动跑一次**。
