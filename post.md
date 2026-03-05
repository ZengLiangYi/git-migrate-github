# 写了个脚本，把 Gitee/GitLab 仓库一键批量迁移到 GitHub

**TL;DR：** 一个 Bash 脚本，通过 GitHub CLI 自动完成「创建仓库 → 替换远程 → 推送代码」全流程。支持批量迁移、敏感文件扫描、dry-run 预览，解决手动迁移的重复劳动问题。

> 本文面向有基本 Git 使用经验的开发者。完整代码：[github.com/ZengLiangYi/git-migrate-github](https://github.com/ZengLiangYi/git-migrate-github)

---

## 起因

最近想把 Gitee 上的几个项目迁移到 GitHub。第一个项目手动操作了一遍：

```bash
gh repo create my-app --private
git remote set-url origin https://github.com/xxx/my-app.git
git push -u origin --all
git push origin --tags
```

四条命令，不复杂。但到第二个项目时，遇到了 GitHub Push Protection —— 历史提交里有一个 `.env` 文件包含云服务密钥，GitHub 直接拒绝推送。

手动处理完第二个，想到还有好几个项目要迁移，每个都要：

1. 记得创建仓库
2. 记得改远程地址
3. 记得推所有分支和标签
4. 记得检查有没有密钥泄露

人工做这种重复操作，迟早漏一步。于是写了个脚本把整个流程自动化。

## 先看效果

单个项目迁移：

```bash
$ ./migrate.sh ~/project/my-app

git-migrate-github v1.0.0
GitHub 账号: ZengLiangYi
迁移数量:    1 个项目
可见性:      private

  → my-app (~/project/my-app)

确认开始迁移？(y/N): y

── my-app ──
  路径:       /home/dev/project/my-app
  GitHub:     ZengLiangYi/my-app (private)
  当前 origin: https://gitee.com/xxx/my-app.git
  分支数量:   3
✓ 仓库创建成功
✓ origin → https://github.com/ZengLiangYi/my-app.git
✓ 所有分支已推送
✓ 所有标签已推送
✓ 完成 → https://github.com/ZengLiangYi/my-app

迁移完成
  成功: 1  失败: 0  总计: 1
```

批量迁移 5 个项目：

```bash
$ ./migrate.sh --file repos.txt --yes
```

就这么多。

## 前置要求

- [Git](https://git-scm.com/)
- [GitHub CLI](https://cli.github.com/)（`gh`）v2.0+

安装 `gh` 后需要先登录：

```bash
gh auth login
```

验证一下：

```bash
$ gh auth status
github.com
  ✓ Logged in to github.com account YourName
```

## 安装

```bash
git clone https://github.com/ZengLiangYi/git-migrate-github.git
cd git-migrate-github
chmod +x migrate.sh
```

或者直接下载单文件：

```bash
curl -fsSL https://raw.githubusercontent.com/ZengLiangYi/git-migrate-github/main/migrate.sh -o migrate.sh
chmod +x migrate.sh
```

## 使用方式

### 场景一：迁移单个项目

最基础的用法，默认创建 **private** 仓库，仓库名取目录名：

```bash
./migrate.sh ~/project/my-app
```

自定义仓库名和可见性：

```bash
./migrate.sh ~/project/my-app --public --name my-cool-app
```

### 场景二：批量迁移

命令行直接传多个路径：

```bash
./migrate.sh --batch ~/project/app1 ~/project/app2 ~/project/app3
```

项目多的话，写个清单文件更方便。创建 `repos.txt`：

```text
~/project/my-app
~/project/my-api
~/project/my-admin
# 这个暂时不迁移
# ~/project/my-old-project
```

然后一条命令搞定，`--yes` 跳过确认：

```bash
./migrate.sh --file repos.txt --yes
```

### 场景三：保留原有远程

迁移后还想保留 Gitee 的远程地址？用 `--keep-remote`：

```bash
./migrate.sh ~/project/my-app --keep-remote
```

效果是原来的 `origin`（Gitee）会被重命名为 `upstream`，新的 `origin` 指向 GitHub：

```bash
$ git remote -v
origin    https://github.com/xxx/my-app.git (push)
upstream  https://gitee.com/xxx/my-app.git (push)
```

这样可以同时向两个平台推送代码。

### 场景四：先预览，再执行

不确定会发生什么？用 `--dry-run`：

```bash
$ ./migrate.sh --file repos.txt --dry-run

git-migrate-github v1.0.0
GitHub 账号: ZengLiangYi
迁移数量:    3 个项目
可见性:      private
模式:        🔍 dry-run (仅预览)

── my-app ──
  路径:       /home/dev/project/my-app
  GitHub:     ZengLiangYi/my-app (private)
  当前 origin: https://gitee.com/xxx/my-app.git
  分支数量:   2
✓ (dry-run) 将创建 ZengLiangYi/my-app 并推送
...
```

不会创建仓库，不会推送，只是告诉你它会做什么。

## 全部选项速查

| 选项 | 说明 | 默认 |
|------|------|------|
| `--public` | 公开仓库 | private |
| `--name <n>` | 自定义仓库名（仅单项目） | 目录名 |
| `--desc <text>` | 仓库描述 | 无 |
| `--keep-remote` | 原 origin → upstream | 替换 origin |
| `--dry-run` | 预览模式 | 关 |
| `--yes` / `-y` | 跳过确认 | 关 |
| `--batch` | 批量模式 | 关 |
| `--file <f>` | 从文件读路径 | 无 |

## 设计细节：脚本做了什么

整个迁移流程 5 步：

```
preflight 检查 → 敏感文件扫描 → 创建 GitHub 仓库 → 设置远程 → 推送
```

逐个拆开看。

### 1. preflight 检查

```bash
preflight() {
    command -v git > /dev/null 2>&1 || fatal "未安装 git"
    command -v gh  > /dev/null 2>&1 || fatal "未安装 GitHub CLI (gh)"
    gh auth status > /dev/null 2>&1  || fatal "GitHub CLI 未登录"
    GH_USER=$(gh api user -q .login 2>/dev/null) || fatal "无法获取 GitHub 用户名"
}
```

在做任何事情之前，先确认环境就绪。`gh api user -q .login` 从 GitHub API 拿到当前登录的用户名，后续拼接仓库 URL 用。

### 2. 敏感文件扫描

```bash
SENSITIVE_PATTERNS='\.env$|\.env\.|credentials?\.json|secret|\.key$|\.pem$|\.p12$|\.pfx$|id_rsa|id_ed25519'

scan_secrets() {
    local files
    files=$(cd "$dir" && git ls-files | grep -iE "$SENSITIVE_PATTERNS" 2>/dev/null || true)
    if [[ -n "$files" ]]; then
        warn "检测到可能含敏感信息的跟踪文件:"
        echo "$files" | while IFS= read -r f; do echo "    - $f"; done
        return 1
    fi
}
```

注意这里用的是 `git ls-files`，只扫描已被 Git 跟踪的文件。未跟踪的文件不会被推送，不需要关心。

覆盖的模式包括：`.env`、`.pem`、`.key`、`credentials.json`、SSH 私钥等。如果仓库设为 `--public`，还会额外给出泄露警告。

这一步只是告警，不会阻止迁移。拦截推送是 GitHub Push Protection 的事。

### 3. 幂等安全

```bash
# 已存在 → 跳过创建
if gh repo view "${GH_USER}/${repo_name}" > /dev/null 2>&1; then
    warn "GitHub 仓库已存在，跳过创建"
fi

# 已迁移 → 跳过
if [[ "$current_origin" == *"github.com/${GH_USER}/${repo_name}"* ]]; then
    warn "跳过 ${repo_name} — origin 已指向 GitHub"
    return 0
fi
```

重复执行不会出错。GitHub 仓库已存在就跳过创建，origin 已指向 GitHub 就跳过迁移。批量操作中途失败，修复后重新跑，已经成功的部分不会受影响。

## 踩坑记录：GitHub Push Protection

这是我写这个脚本的直接诱因。当你往 GitHub 推送时，如果历史提交中包含密钥（云厂商 Secret Key、API Token 等），GitHub 会直接拒绝：

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - GITHUB PUSH PROTECTION
remote:     - Push cannot contain secrets
remote:
remote:       —— Tencent Cloud Secret ID ———————————————
remote:        locations:
remote:          - commit: 5838fbb
remote:            path: .env:8
```

注意：这不是只看当前文件有没有密钥，而是扫描**所有历史提交**。哪怕你在最新提交里删掉了 `.env`，之前的提交里还有，照样拒绝。

**解决方案有两个：**

**方案一**：用 `git-filter-repo` 从历史中彻底清除（推荐）

```bash
pip install git-filter-repo
git filter-repo --path .env --invert-paths
```

这会重写 Git 历史，所有包含 `.env` 的提交都会被修改。注意：如果有其他人 clone 过这个仓库，他们需要重新 clone。

**方案二**：把仓库设为 private

私有仓库的 Push Protection 策略更宽松，通常不会拦截。但这不意味着密钥安全——任何有仓库访问权限的人都能看到。

**最佳实践**：从一开始就把 `.env` 加入 `.gitignore`，永远不要提交密钥到 Git。

## 局限性

坦诚讲几个这个脚本做不到的事：

- **不会清理 Git 历史**：脚本只负责迁移，不会帮你删除历史中的敏感信息。遇到 Push Protection 拦截需要手动处理。
- **不迁移 Issue / PR / Wiki**：这些是平台特定的数据，Git 本身不包含。需要的话可以看看 GitHub 官方的 [仓库导入工具](https://github.com/new/import)。
- **不处理 LFS**：如果仓库用了 Git LFS，需要额外配置。
- **依赖 `gh` CLI**：没有用裸 API，依赖 GitHub CLI 的认证和仓库创建能力。

## 总结

| 手动迁移 | 用脚本 |
|---------|--------|
| 每个项目 4-5 条命令 | 一条命令 |
| 容易忘记推标签 | 自动推送所有分支和标签 |
| 密钥泄露靠运气发现 | 推送前自动扫描告警 |
| 中断后不知道做到哪了 | 幂等安全，重跑即可 |
| 批量操作手动循环 | `--file repos.txt` |

完整代码和文档在这里：**[github.com/ZengLiangYi/git-migrate-github](https://github.com/ZengLiangYi/git-migrate-github)**

如果帮到你了，欢迎 star。有问题或建议，直接提 issue。
