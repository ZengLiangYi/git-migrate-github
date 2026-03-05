#!/usr/bin/env bash
# git-migrate-github — 将本地 Git 仓库批量迁移到 GitHub
# https://github.com/ZengLiangYi/git-migrate-github

set -euo pipefail

VERSION="1.0.0"

# ──────────────────────── 颜色 & 日志 ────────────────────────
RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
CYAN='\033[0;36m' BOLD='\033[1m'      NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }
fatal() { error "$1"; exit 1; }
title() { echo -e "\n${BOLD}${CYAN}$1${NC}"; }

# ──────────────────────── 默认值 ────────────────────────
VISIBILITY="private"
DRY_RUN=false
KEEP_OLD_REMOTE=false
OLD_REMOTE_NAME="upstream"
SKIP_CONFIRM=false
REPO_NAME=""
DESCRIPTION=""

# ──────────────────────── 帮助信息 ────────────────────────
usage() {
    cat <<'EOF'
git-migrate-github — 将本地 Git 仓库迁移到 GitHub

用法:
  单个项目:    ./migrate.sh <项目路径> [选项]
  批量迁移:    ./migrate.sh --batch <路径1> <路径2> ... [选项]
  从文件读取:  ./migrate.sh --file <list.txt> [选项]

选项:
  --public              设为公开仓库 (默认: private)
  --name <name>         自定义 GitHub 仓库名 (默认: 目录名)
  --desc <text>         仓库描述
  --keep-remote         保留原有 origin 为 upstream，GitHub 设为新 origin
  --dry-run             仅预览操作，不实际执行
  --yes                 跳过确认提示
  --batch               批量模式，后跟多个路径
  --file <file>         从文件读取路径列表 (每行一个路径)
  --version             显示版本号
  -h, --help            显示帮助信息

示例:
  ./migrate.sh ~/project/my-app
  ./migrate.sh ~/project/my-app --public --name my-cool-app
  ./migrate.sh --batch ~/project/app1 ~/project/app2 --keep-remote
  ./migrate.sh --file repos.txt --yes

list.txt 格式:
  ~/project/app1
  ~/project/app2
  # 以 # 开头的行会被跳过
EOF
    exit 0
}

# ──────────────────────── 参数解析 ────────────────────────
PATHS=()
BATCH_MODE=false
BATCH_FILE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)    usage ;;
            --version)    echo "git-migrate-github v${VERSION}"; exit 0 ;;
            --public)     VISIBILITY="public" ;;
            --private)    VISIBILITY="private" ;;
            --name)       REPO_NAME="${2:?'--name 需要参数'}"; shift ;;
            --desc)       DESCRIPTION="${2:?'--desc 需要参数'}"; shift ;;
            --keep-remote) KEEP_OLD_REMOTE=true ;;
            --dry-run)    DRY_RUN=true ;;
            --yes|-y)     SKIP_CONFIRM=true ;;
            --batch)      BATCH_MODE=true ;;
            --file)       BATCH_FILE="${2:?'--file 需要参数'}"; shift ;;
            -*)           fatal "未知选项: $1 (使用 --help 查看帮助)" ;;
            *)            PATHS+=("$1") ;;
        esac
        shift
    done

    # 从文件读取路径
    if [[ -n "$BATCH_FILE" ]]; then
        [[ -f "$BATCH_FILE" ]] || fatal "文件不存在: $BATCH_FILE"
        while IFS= read -r line; do
            line=$(echo "$line" | xargs)  # trim
            [[ -z "$line" || "$line" == \#* ]] && continue
            PATHS+=("$line")
        done < "$BATCH_FILE"
    fi

    [[ ${#PATHS[@]} -eq 0 ]] && fatal "请提供至少一个项目路径 (使用 --help 查看帮助)"

    # --name 只在单项目模式下生效
    if [[ -n "$REPO_NAME" && ${#PATHS[@]} -gt 1 ]]; then
        fatal "--name 不能在批量模式下使用 (每个项目会自动使用目录名)"
    fi
}

# ──────────────────────── 前置检查 ────────────────────────
preflight() {
    command -v git > /dev/null 2>&1 || fatal "未安装 git"
    command -v gh  > /dev/null 2>&1 || fatal "未安装 GitHub CLI (gh)，请访问 https://cli.github.com 安装"
    gh auth status > /dev/null 2>&1  || fatal "GitHub CLI 未登录，请运行: gh auth login"
    GH_USER=$(gh api user -q .login 2>/dev/null) || fatal "无法获取 GitHub 用户名"
}

# ──────────────────────── 敏感文件扫描 ────────────────────────
SENSITIVE_PATTERNS='\.env$|\.env\.|credentials?\.json|secret|\.key$|\.pem$|\.p12$|\.pfx$|id_rsa|id_ed25519'

scan_secrets() {
    local dir="$1"
    local files
    files=$(cd "$dir" && git ls-files | grep -iE "$SENSITIVE_PATTERNS" 2>/dev/null || true)
    if [[ -n "$files" ]]; then
        warn "检测到可能含敏感信息的跟踪文件:"
        echo "$files" | while IFS= read -r f; do echo "    - $f"; done
        return 1
    fi
    return 0
}

# ──────────────────────── 单个项目迁移 ────────────────────────
migrate_one() {
    local project_path="$1"
    local repo_name="$2"

    # 解析绝对路径
    project_path=$(cd "$project_path" 2>/dev/null && pwd) || {
        error "路径不存在: $1"; return 1
    }

    # 验证 git 仓库
    (cd "$project_path" && git rev-parse --git-dir > /dev/null 2>&1) || {
        error "不是 Git 仓库: $project_path"; return 1
    }

    # 默认用目录名
    [[ -z "$repo_name" ]] && repo_name=$(basename "$project_path")

    local github_url="https://github.com/${GH_USER}/${repo_name}.git"
    local current_origin
    current_origin=$(cd "$project_path" && git remote get-url origin 2>/dev/null || echo "")

    # 检查是否已经指向 GitHub
    if [[ "$current_origin" == *"github.com/${GH_USER}/${repo_name}"* ]]; then
        warn "跳过 ${repo_name} — origin 已指向 GitHub"
        return 0
    fi

    title "── ${repo_name} ──"
    echo "  路径:       $project_path"
    echo "  GitHub:     ${GH_USER}/${repo_name} (${VISIBILITY})"
    [[ -n "$current_origin" ]] && echo "  当前 origin: $current_origin"

    local branch_count
    branch_count=$(cd "$project_path" && git branch | wc -l | xargs)
    echo "  分支数量:   $branch_count"

    # 敏感文件扫描
    if ! scan_secrets "$project_path"; then
        if [[ "$VISIBILITY" == "public" ]]; then
            warn "⚠ 公开仓库可能泄露上述敏感文件!"
        fi
    fi

    # dry-run 到此为止
    if $DRY_RUN; then
        info "(dry-run) 将创建 ${GH_USER}/${repo_name} 并推送"
        return 0
    fi

    # ── 执行迁移 ──

    # 1. 创建 GitHub 仓库
    if gh repo view "${GH_USER}/${repo_name}" > /dev/null 2>&1; then
        warn "GitHub 仓库已存在，跳过创建"
    else
        local desc_flag=""
        [[ -n "$DESCRIPTION" ]] && desc_flag="--description=${DESCRIPTION}"
        if gh repo create "$repo_name" "--${VISIBILITY}" ${desc_flag:+"$desc_flag"} 2>/dev/null; then
            info "仓库创建成功"
        else
            error "创建仓库失败: ${repo_name}"; return 1
        fi
    fi

    # 2. 设置远程
    cd "$project_path"
    if [[ -n "$current_origin" ]]; then
        if $KEEP_OLD_REMOTE; then
            # 保留旧 origin → 重命名为 upstream
            if git remote get-url "$OLD_REMOTE_NAME" > /dev/null 2>&1; then
                warn "${OLD_REMOTE_NAME} 远程已存在，跳过重命名"
            else
                git remote rename origin "$OLD_REMOTE_NAME"
                info "原 origin 已重命名为 ${OLD_REMOTE_NAME}"
            fi
            git remote add origin "$github_url" 2>/dev/null || git remote set-url origin "$github_url"
        else
            git remote set-url origin "$github_url"
        fi
    else
        git remote add origin "$github_url"
    fi
    info "origin → ${github_url}"

    # 3. 推送
    if git push -u origin --all 2>&1; then
        info "所有分支已推送"
    else
        error "推送分支失败 (可能触发了 GitHub Push Protection)"
        error "请清除历史中的敏感信息后重试，参考: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository"
        return 1
    fi

    git push origin --tags 2>&1 && info "所有标签已推送"

    info "完成 → https://github.com/${GH_USER}/${repo_name}"
    return 0
}

# ──────────────────────── 主流程 ────────────────────────
main() {
    parse_args "$@"
    preflight

    local total=${#PATHS[@]}
    local success=0
    local failed=0
    local skipped=0

    title "git-migrate-github v${VERSION}"
    echo "GitHub 账号: ${GH_USER}"
    echo "迁移数量:    ${total} 个项目"
    echo "可见性:      ${VISIBILITY}"
    $DRY_RUN      && echo "模式:        🔍 dry-run (仅预览)"
    $KEEP_OLD_REMOTE && echo "保留旧远程:  是 (重命名为 ${OLD_REMOTE_NAME})"

    # 预览列表
    echo ""
    for p in "${PATHS[@]}"; do
        local name
        name=$(basename "$(cd "$p" 2>/dev/null && pwd 2>/dev/null || echo "$p")")
        echo "  → $name ($p)"
    done

    # 确认
    if ! $SKIP_CONFIRM && ! $DRY_RUN; then
        echo ""
        read -rp "确认开始迁移？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
    fi

    # 逐个迁移
    for p in "${PATHS[@]}"; do
        local name="$REPO_NAME"
        if migrate_one "$p" "$name"; then
            ((success++))
        else
            ((failed++))
        fi
    done

    # 汇总
    title "迁移完成"
    echo "  成功: ${success}  失败: ${failed}  总计: ${total}"

    [[ $failed -gt 0 ]] && exit 1
    exit 0
}

main "$@"
