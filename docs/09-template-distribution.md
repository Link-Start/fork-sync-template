# 09. 模板分发:让别人 fork 走就能用

**Q: 我可以建一个专门的仓库,让其他人 fork 走就能直接用,而且能选风格吗?**

**A: 可以。** 模板里**两种风格的 yml 都放上**,fork 者自己选,不用创建 yml。

把「独立配置仓库」(见 [01-architecture.md](01-architecture.md))思想扩展到**多用户分发**场景。

---

## 两种风格白话解释 (给完全没基础的人)

读这一节之前,你只需要知道一件事:**GitHub Actions 是一种"自动跑脚本"的机制**。`.yml` 文件里写"什么时候跑 + 跑什么",GitHub 就会自动执行。

下面解释的两种风格,就是两种不同的"跑什么"写法。

### 风格 1: 静态 matrix

**白话**: 你在 yml 里**手写一个清单**,列出所有要同步的 fork 名。Workflow 按这个清单跑。

**例子** (yml 里的核心部分):
```yaml
matrix:
  fork:
    - { fork_repo: Spider_XHS_cv-cat,     upstream_repo: Spider_XHS }
    - { fork_repo: OpenFeiShuApis-cv-cat, upstream_repo: OpenFeiShuApis }
    - { fork_repo: WechatOAApis-cv-cat,   upstream_repo: WechatOAApis }
    # 一行一个 fork,写死
```

**类比**: 像冰箱上贴了一个"待办清单",workflow 每天按清单逐个处理。**新增 fork = 手动加一行,删除 fork = 手动删一行。**

**特点**:
- ✅ 简单直接,清单一目了然
- ❌ 新 fork 一个仓库要手动加一行
- ❌ 删了某个 fork 要手动删一行
- ❌ **适合 fork 数量固定不变的人**

---

### 风格 2: 动态发现

**白话**: yml 里**不写清单**,workflow 启动时自动去 GitHub 问"我有几个 fork",然后全部同步。

**例子** (yml 里的核心部分):
```yaml
forks=$(gh api 'user/repos?per_page=100&type=owner&sort=updated' \
        --jq '[.[] | select(.fork == true and .parent != null)]')
# 拿到的 forks 自动处理,不用手写
```

**类比**: 像雇了一个助理,每天早上他自己数你有多少个 fork,然后全帮你同步。**你完全不用管清单。**

**特点**:
- ✅ 免维护 fork 列表,新 fork 进来自动同步
- ✅ 删了 fork 自动跳过
- ✅ **适合 fork 数量会变 / 想省心的人** (推荐)
- ❌ yml 比风格 1 复杂一点 (但 fork 者不用改)

---

## 两种风格关键区别

| 维度 | 风格 1 静态 matrix | 风格 2 动态发现 |
|---|---|---|
| yml 复杂度 | 简单 (几行 matrix) | 复杂 (有循环逻辑) |
| **fork 者要不要改 yml** | ✅ 要 (改 matrix 列表) | ❌ 不用 |
| 新增 fork | 手动加 matrix 项 | 自动包含 |
| 删除 fork | 手动删 matrix 项 | 自动跳过 |
| 适合谁 | fork 数量固定 (8 个不变) | fork 数量会变 / 想省心 |
| 总体推荐 | 适合**小且固定**的场景 | ✅ **适合大多数人** |

---

## 模板仓库长什么样

```
<你的账号>/fork-sync-template/
├── .github/workflows/
│   └── sync-dynamic.yml             # ✅ 默认开,作者日常使用版 (默认排除 claude 相关)
├── examples/
│   ├── sync-dynamic.yml             # 通用模板: 动态发现 (fork 者可选用,免维护 fork 列表)
│   └── sync-static.yml              # 通用模板: 静态 matrix (fork 者可选用,要手写列表)
└── README.md                         # 给 fork 者的指引
```

### 文件夹结构解释 (给完全没基础的人)

| 文件夹/文件 | 是干啥的 |
|---|---|
| `.github/workflows/` | GitHub 规定放 workflow 文件的文件夹。里面所有 `.yml` 文件都会被 GitHub 当作 workflow 自动跑。 |
| `examples/` | 放示例/备选文件的地方。里面的 yml **不会**被 GitHub 当 workflow 跑 (因为不在 `.github/workflows/` 里),只是"参考"用。 |
| `README.md` | 仓库的说明文档,给 fork 者看怎么用。 |

### 为什么静态 matrix 和通用动态版都放 `examples/` 而不是 `.github/workflows/`

- 这两个 yml 都是**通用模板**,fork 者可能想自己改或者根本不想用
- 静态 matrix 的 yml 里**写死了 fork 名** (模板作者的 fork),没改就跑会出 bug
- 放 `examples/` 强制 fork 者**主动决定**要不要用,**不会一 fork 就跑出乱子**
- 只有 `.github/workflows/sync-dynamic.yml` 是作者日常配置,fork 后直接跑就对(默认排除 claude 相关)

---

## fork 者两种选择 (Step by Step)

### 选项 A: 动态发现 (推荐,90% 的人选这个)

**总共 4 步,不用改任何 yml。**

**Step 1: Fork 模板**
- 打开 `Link-Start/fork-sync-template`
- 点右上角 **Fork** 按钮
- 选自己的账号
- 得到 `你的用户名/fork-sync-template`

**Step 2: 开 workflow 写权限**
- 进 `你的用户名/fork-sync-template`
- 顶部菜单点 **Settings**
- 左边菜单点 **Actions** → **General**
- 找到 **Workflow permissions**
- 选 **Read and write permissions**
- 点 **Save**

**Step 3: 配置跨仓库 token**
- 还是在这个配置仓库的 **Settings**
- 点 **Secrets and variables** → **Actions**
- 新增 repository secret: `FORK_SYNC_TOKEN`
- 值用 fork 者自己的 PAT,至少给目标 fork `Contents: Read and write`

**Step 4: 开定时任务**
- 进 **Actions** 标签页
- 看到黄色提示 "Workflows aren't being run on this forked repository"
- 点 **"I understand my workflows, go ahead and enable them"**

**完事。** `sync-dynamic.yml` 会自动跑,扫描你账号下所有 fork,逐个同步。

✅ 不用改任何 yml
✅ 不用维护 fork 列表

---

### 选项 B: 静态 matrix

**适合:你的 fork 数量固定,想精确控制哪些同步。**

**总共 5 步,要改 yml。**

**Step 1: Fork 模板**
- (跟选项 A 的 Step 1 一样)

**Step 2: 编辑 `examples/sync-static.yml`**
- 进 `examples/` 文件夹
- 点进 `sync-static.yml`
- 点右上角**铅笔图标** ✏️ (Edit this file)
- 找到 `matrix.fork:` 那一段
- 改成你自己的 fork 列表,例如:

```yaml
matrix:
  fork:
    - { fork_repo: 我的-Spider-fork,     upstream_repo: Spider_XHS }
    - { fork_repo: 我的-Bilibili-fork,   upstream_repo: BilibiliApis }
    - { fork_repo: 我的-Zhihu-fork,      upstream_repo: ZhihuApis }
    # 一行一个 fork
```

- 滚到页面底部
- Commit message 写: `ci: customize matrix for my forks`
- 点 **Commit changes** 绿色按钮

**Step 3: 把改好的文件移到 `.github/workflows/`**
- 在 `.github/workflows/` 文件夹里
- 点 **Add file** → **Create new file**
- 文件名填 `sync-static.yml`
- 内容粘贴你刚改好的内容
- 底部 Commit

**Step 4: 删掉 `sync-dynamic.yml` (避免两个都跑重复执行)**
- 进 `.github/workflows/` 文件夹
- 点进 `sync-dynamic.yml`
- 点右上角**垃圾桶图标** 🗑️ (Delete this file)
- 底部 Commit

**Step 5: token + 开权限 + 开定时任务**
- 跟选项 A 的 Step 2、Step 3、Step 4 一样
- Settings → Secrets and variables → Actions → 新增 `FORK_SYNC_TOKEN`
- Settings → Actions → General → Workflow permissions → "Read and write permissions"
- Actions 标签页 → "I understand my workflows, go ahead and enable them"

完事。

---

## 两种选项对比 (fork 者视角)

| 步骤 | 选项 A 动态发现 | 选项 B 静态 matrix |
|---|---|---|
| 1. Fork 模板 | ✅ | ✅ |
| 2. 改 yml | ❌ 不用 | ✅ 要改 matrix 列表 |
| 3. 删除/移动文件 | ❌ 不用 | ✅ 删 sync-dynamic,移 sync-static |
| 4. 配置 `FORK_SYNC_TOKEN` | ✅ | ✅ |
| 5. 开写权限 | ✅ | ✅ |
| 6. 开定时任务 | ✅ | ✅ |
| **改 yml 工作量** | **0** | **要** |
| **维护成本** | **低** (不用维护 fork 列表) | **高** (加 fork 要改 yml) |
| **适合谁** | **多数人 (推荐)** | fork 数量固定 / 想精确控制 |

---

## fork 者怎么跳过不想同步的 fork

两种办法都行,**决定权在 fork 者自己**:

### 方法 1 (推荐): 在 fork 自己的仓库加 `.github/.no-sync`

在自己某个 fork (比如 `你的用户名/SomeFork`) 加个文件 `.github/.no-sync`:
- 内容随便写
- workflow 检测到就跳过这个 fork
- 改 fork 仓库的设置就行,不用动模板

详见 [07-skip-mechanisms.md](07-skip-mechanisms.md)。

### 方法 2: 在配置仓库加 `skip.txt`

在 `你的用户名/fork-sync-template` 根目录加 `skip.txt`,每行一个 fork 名:

```
my-personal-experiment
legacy-fork-dont-touch
# 注释行,开头 # 忽略
```

workflow 跑的时候跳过列表里的 fork。

集中管理,但要去配置仓库改。

---

## 安全性:对模板作者零风险

- workflow 用的是 **fork 者自己的 `FORK_SYNC_TOKEN` / `GITHUB_TOKEN`**,跑在 fork 者自己的 runner 上
- 不会访问你(模板作者)的任何东西
- fork 者看到 yml 不放心,自己改了再跑就行,代码完全开源可见

---

## 实际部署示例

### 你 (`Link-Start`)

```
Link-Start/
├── Spider_XHS_cv-cat/                  # 你自己的 fork
├── Spider_XHS_cv-cat-sync/             # 你的私有 config 仓库
├── ...
└── fork-sync-template/                 # 公共模板,给所有人用
    ├── .github/workflows/
    │   └── sync-dynamic.yml                # 默认,作者日常使用 (排除 claude 相关)
    ├── examples/
    │   ├── sync-dynamic.yml                # 通用动态模板
    │   └── sync-static.yml                 # 通用静态模板
    ├── README.md                              # fork 指引 (模板)
    └── docs/                                  # 01-09 文档 (可选)
```

### fork 者 (Bob)

```
Bob/
├── (他 N 个 fork)                       # 自动被同步
├── ...
└── fork-sync-template/                  # Bob 从你这里 fork 的
    ├── .github/workflows/
    │   └── sync-dynamic.yml (或换成 examples/sync-static.yml,二选一)
    └── skip.txt (可选)
```

---

## 模板作者 README 怎么写 (给 fork 者的"指引")

把上面 fork 者选项 A/B 的步骤精简成一段话,放到模板仓库的 README 里:

````markdown
# Fork Sync Template

[你的描述]

## 怎么用

### 方式 1: 动态发现 (推荐)

1. Fork 这个仓库
2. Settings → Secrets and variables → Actions 新增 `FORK_SYNC_TOKEN`
3. Settings → Actions → General → Workflow permissions 选 "Read and write permissions"
4. Actions 标签页点 "I understand my workflows, go ahead and enable them"
5. 完事。`sync-dynamic.yml` 会自动跑,同步你名下所有 fork。

### 方式 2: 静态 matrix (适合 fork 数量固定)

1. Fork 这个仓库
2. 编辑 `examples/sync-static.yml`,把 matrix 列表改成你自己的 fork
3. 把改好的文件移到 `.github/workflows/sync-static.yml`
4. 删掉 `sync-dynamic.yml` (避免重复)
5. Settings → Secrets and variables → Actions 新增 `FORK_SYNC_TOKEN`
6. Settings → Actions → General → Workflow permissions 选 "Read and write permissions"
7. Actions 标签页点 "I understand my workflows, go ahead and enable them"

## 跳过某些 fork

在那个 fork 自己仓库加 `.github/.no-sync` 文件就行 (内容随便写)。
详见 [07-skip-mechanisms.md](docs/07-skip-mechanisms.md)。
````

---

## 这个模式 vs 自己部署

| 维度 | 自己部署 | 模板分发 |
|---|---|---|
| 你自己用 | ✅ | ✅ |
| 别人也能用 | ❌ | ✅ |
| yml 维护 | 每处各维护一份 | 一份,所有人共用 |
| fork 者跳过不想同步的 fork | 用 .no-sync / skip.txt | 用 .no-sync / skip.txt (一样) |
| 安全风险 | 0 | 0 (fork 者用自己的 `FORK_SYNC_TOKEN` / `GITHUB_TOKEN`) |

---

## 建议

- 默认推荐动态发现 (`sync-dynamic.yml`),90% 的人用这个
- 静态 matrix 放 `examples/` 备选,留给有特殊需求的人
- 模板 README 里把"动态发现 4 步"放在最显眼位置,大多数 fork 者只关心这个
- 如果想加更多选项(比如 filter upstream owner),可以加在动态发现的 `workflow_dispatch` input 里,跟 fork 数量无关
