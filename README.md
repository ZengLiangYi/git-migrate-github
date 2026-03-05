# git-migrate-github

将本地 Git 仓库一键迁移到 GitHub，支持批量操作。

适用于从 Gitee、GitLab、Bitbucket 或其他平台迁移到 GitHub 的场景。

## 功能

- **单项目 / 批量迁移** — 一条命令搞定一个或多个仓库
- **敏感文件扫描** — 推送前自动检测 `.env`、密钥等文件并告警
- **保留旧远程** — 可将原 `origin` 重命名为 `upstream`，同时维护两个远程
- **dry-run 预览** — 先看会做什么，再决定是否执行
- **自动创建仓库** — 调用 `gh` CLI 创建 GitHub 仓库，无需手动操作

## 前置要求

- [Git](https://git-scm.com/)
- [GitHub CLI (`gh`)](https://cli.github.com/) — 已登录 (`gh auth login`)

## 安装

```bash
git clone https://github.com/ZengLiangYi/git-migrate-github.git
cd git-migrate-github
chmod +x migrate.sh
```

或者直接下载脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/ZengLiangYi/git-migrate-github/main/migrate.sh -o migrate.sh
chmod +x migrate.sh
```

## 快速开始

```bash
# 迁移单个项目 (默认 private)
./migrate.sh ~/project/my-app

# 迁移为公开仓库，自定义名称
./migrate.sh ~/project/my-app --public --name my-cool-app

# 保留 Gitee 远程为 upstream
./migrate.sh ~/project/my-app --keep-remote

# 先预览，不执行
./migrate.sh ~/project/my-app --dry-run
```

## 批量迁移

### 方式一：命令行传入多个路径

```bash
./migrate.sh --batch ~/project/app1 ~/project/app2 ~/project/app3
```

### 方式二：从文件读取

创建 `repos.txt`：

```text
~/project/app1
~/project/app2
~/project/app3
# 以 # 开头的行会被跳过
```

执行：

```bash
./migrate.sh --file repos.txt --yes
```

## 全部选项

| 选项 | 说明 | 默认值 |
|------|------|--------|
| `--public` | 公开仓库 | `private` |
| `--private` | 私有仓库 | ✓ |
| `--name <name>` | 自定义仓库名（单项目模式） | 目录名 |
| `--desc <text>` | 仓库描述 | - |
| `--keep-remote` | 保留原 origin 为 upstream | 替换 origin |
| `--dry-run` | 仅预览，不执行 | - |
| `--yes`, `-y` | 跳过确认提示 | - |
| `--batch` | 批量模式 | - |
| `--file <file>` | 从文件读取路径 | - |
| `--version` | 显示版本号 | - |
| `-h`, `--help` | 显示帮助 | - |

## 迁移流程

脚本执行以下操作：

```
1. 验证环境 (git / gh CLI / 登录状态)
2. 扫描敏感文件并告警
3. 在 GitHub 创建同名仓库
4. 设置 origin 指向 GitHub
   - 默认: 替换原 origin
   - --keep-remote: 原 origin → upstream, 新 origin → GitHub
5. 推送所有分支和标签
```

## 注意事项

### GitHub Push Protection

如果历史提交中包含密钥（如云服务 SecretKey），GitHub 会拒绝推送。解决方案：

1. **推荐**：用 [git-filter-repo](https://github.com/newren/git-filter-repo) 清除历史中的敏感信息
2. 改用 `--private` 私有仓库（Push Protection 对私有仓库更宽松）

```bash
# 安装 git-filter-repo
pip install git-filter-repo

# 从所有历史中删除 .env 文件
git filter-repo --path .env --invert-paths
```

### 迁移后

- 记得更新本地其他 clone 的远程地址
- 如果原平台有 CI/CD，需要在 GitHub 重新配置
- 建议迁移后轮换（更新）所有暴露过的密钥

## License

[MIT](LICENSE)
