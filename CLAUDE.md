# Fork Sync Template

GitHub Actions workflow模板仓库，用于自动同步 fork 到上游。

## 语言要求

除非必须（如英文标识符、命令、API 字段名等），所有交流与产出一律使用中文：
- 与用户交流用中文
- 代码注释、文档、README 用中文
- Commit message 用中文（保留 conventional commits 前缀）
- 禁止用其他语言与用户交流

## 项目结构

```
├── .github/workflows/
│   ├── sync-dynamic.yml      # 动态发现版 (默认排除 claude)
│   ├── health-check.yml       # 健康检查
│   └── rollback.yml          # 手动回滚 backup tag
├── examples/
│   ├── sync-dynamic.yml      # 通用动态模板
│   └── sync-static.yml       # 静态 matrix 模板
├── docs/                      # 10 篇文档
└── README.md
```

## 常用操作

### 本地测试 workflow

直接用 `act` 运行（需先安装）：
```bash
act workflow_dispatch
```

### 验证 YAML 语法

```bash
# 使用 yamllint（如果安装）
yamllint .github/workflows/
```

### 查看文档

```bash
#快速浏览
ls docs/
cat docs/01-architecture.md
```

## Commit 规范

使用 conventional commits：

- `feat:` 新功能
- `fix:` Bug 修复
- `docs:` 文档更新
- `chore:` 维护任务（如 drift state 更新）
- `refactor:` 重构

## 注意事项

1. 这是**模板仓库**，不要在这里直接配置使用
2. Fork 后根据 README 的指导启用 workflow
3. `.omx/` 目录是本地运行状态，不提交到 git
4. workflow 文件使用 `${{ secrets.FORK_SYNC_TOKEN }}` 获取 PAT