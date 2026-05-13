#!/bin/bash
# sync-to-obsidian.sh
# 将每日论文同步到 Obsidian 笔记库
#
# 用法: ./sync-to-obsidian.sh
# 建议配合 cron 使用，例如每天 02:00 执行（GitHub Action 北京时间 01:00 跑完）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAILY_PAPERS_DIR="$SCRIPT_DIR"
OBSIDIAN_DIR="/home/harrycrab/Obsidian"
OBSIDIAN_SYNC_BRANCH="obsidian-sync"
ARXIV_SYNC_BRANCH="arXiv-sync"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========== 0. 确认 Obsidian 是 git 仓库 ==========
if ! git -C "$OBSIDIAN_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    log_error "Obsidian 目录不是 git 仓库: $OBSIDIAN_DIR"
    exit 1
fi

# ========== 1. 拉取 daily-papers 的 arXiv-sync 分支 ==========
log_info "拉取 daily-papers 的 $ARXIV_SYNC_BRANCH 分支..."

cd "$DAILY_PAPERS_DIR"
git fetch origin arXiv-sync 2>/dev/null || true

if git rev-parse --verify origin/arXiv-sync > /dev/null 2>&1; then
    # 临时检出到 worktree
    WORKTREE_DIR="$DAILY_PAPERS_DIR/.obsidian-sync-worktree"
    mkdir -p "$WORKTREE_DIR"

    # 用 worktree 拉取，避免干扰主工作区
    if git -C "$DAILY_PAPERS_DIR" worktree list | grep -q "$WORKTREE_DIR"; then
        git -C "$DAILY_PAPERS_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    fi

    git -C "$DAILY_PAPERS_DIR" worktree add -f "$WORKTREE_DIR" "origin/arXiv-sync" 2>/dev/null || {
        # worktree 不可用则直接 checkout
        log_warn "worktree 不可用，使用直接 checkout 方式"
        WORKTREE_DIR="$DAILY_PAPERS_DIR/.obsidian-temp-sync"
        mkdir -p "$WORKTREE_DIR"
        git -C "$DAILY_PAPERS_DIR" checkout origin/arXiv-sync -- "$WORKTREE_DIR" 2>/dev/null || {
            log_warn "无法拉取 arXiv-sync 分支，可能还没有内容"
            exit 0
        }
    }

    IMPORT_DIR="$WORKTREE_DIR/obsidian-import"

    if [ ! -d "$IMPORT_DIR" ]; then
        log_warn "没有找到 obsidian-import 目录，跳过同步"
        rm -rf "$WORKTREE_DIR"
        exit 0
    fi

    log_info "找到论文导入目录: $IMPORT_DIR"
    ls -la "$IMPORT_DIR/"

    # ========== 2. 准备 Obsidian sync 分支 ==========
    log_info "切换到 Obsidian vault 的 $OBSIDIAN_SYNC_BRANCH 分支..."

    cd "$OBSIDIAN_DIR"

    # 配置变基策略（遇到冲突用 rebase 解决）
    git config pull.rebase true
    git config rebase.autostash true

    # 切换或创建 obsidian-sync 分支
    if git rev-parse --verify "$OBSIDIAN_SYNC_BRANCH" > /dev/null 2>&1; then
        git checkout "$OBSIDIAN_SYNC_BRANCH"
        # 变基拉取最新
        git fetch origin
        git rebase origin/main 2>/dev/null || {
            log_warn "rebase 遇到冲突，请手动解决后继续"
            git rebase --abort || true
            exit 1
        }
    else
        # 从 main 创建新分支
        git checkout -b "$OBSIDIAN_SYNC_BRANCH"
    fi

    # ========== 3. 按类型拷贝到 Obsidian 目录 ==========
    log_info "按类型拷贝论文到 Obsidian 目录..."

    # EDA 论文 → 论文/EDA/
    if [ -d "$IMPORT_DIR/EDA" ]; then
        mkdir -p "$OBSIDIAN_DIR/论文/EDA/arXiv"
        cp -f "$IMPORT_DIR/EDA/"*.md "$OBSIDIAN_DIR/论文/EDA/arXiv/" 2>/dev/null || true
        log_info "已拷贝 EDA 论文到 论文/EDA/arXiv/"
    fi

    # TCAD 论文 → 论文/TCAD/
    if [ -d "$IMPORT_DIR/TCAD" ]; then
        mkdir -p "$OBSIDIAN_DIR/论文/TCAD/arXiv"
        cp -f "$IMPORT_DIR/TCAD/"*.md "$OBSIDIAN_DIR/论文/TCAD/arXiv/" 2>/dev/null || true
        log_info "已拷贝 TCAD 论文到 论文/TCAD/arXiv/"
    fi

    # AI/ML 论文 → 论文/大模型/（或其他 AI 相关目录）
    if [ -d "$IMPORT_DIR/AI_ML" ]; then
        mkdir -p "$OBSIDIAN_DIR/论文/大模型/arXiv"
        cp -f "$IMPORT_DIR/AI_ML/"*.md "$OBSIDIAN_DIR/论文/大模型/arXiv/" 2>/dev/null || true
        log_info "已拷贝 AI/ML 论文到 论文/大模型/arXiv/"
    fi

    # 也生成一份汇总，命名为当天日期
    TODAY=$(date +'%Y-%m-%d')
    if [ -d "$IMPORT_DIR/EDA" ] || [ -d "$IMPORT_DIR/TCAD" ] || [ -d "$IMPORT_DIR/AI_ML" ]; then
        mkdir -p "$OBSIDIAN_DIR/论文/每日汇总"
        # 合并所有论文为一份汇总
        SUMMARY_FILE="$OBSIDIAN_DIR/论文/每日汇总/${TODAY}_arXiv_论文.md"
        {
            echo "# arXiv 每日论文 - $TODAY"
            echo ""
            echo "> 自动从 daily-papers 同步，branch: $OBSIDIAN_SYNC_BRANCH"
            echo ""
        } > "$SUMMARY_FILE"

        for subdir in EDA TCAD AI_ML; do
            if [ -d "$IMPORT_DIR/$subdir" ] && [ "$(ls -A "$IMPORT_DIR/$subdir/"*.md 2>/dev/null | wc -l)" -gt 0 ]; then
                echo "## $subdir" >> "$SUMMARY_FILE"
                echo "" >> "$SUMMARY_FILE"
                cat "$IMPORT_DIR/$subdir/"*.md >> "$SUMMARY_FILE"
                echo "" >> "$SUMMARY_FILE"
            fi
        done
        log_info "已生成汇总: $SUMMARY_FILE"
    fi

    # ========== 4. 提交并推送 ==========
    cd "$OBSIDIAN_DIR"
    git add 论文/EDA/arXiv/ 论文/TCAD/arXiv/ 论文/大模型/arXiv/ 论文/每日汇总/ 2>/dev/null || true

    if git diff --quiet && git diff --staged --quiet; then
        log_info "没有新内容要提交"
    else
        log_info "提交更改..."
        git commit -m "📚 sync: 同步 arXiv 论文 $(date +'%Y-%m-%d')"

        log_info "推送到远端 $OBSIDIAN_SYNC_BRANCH 分支..."
        git push -u origin "$OBSIDIAN_SYNC_BRANCH"
        log_info "✅ Obsidian 同步完成！"
    fi

    # ========== 5. 清理 ==========
    # 清理 worktree
    cd "$DAILY_PAPERS_DIR"
    if [ -d "$WORKTREE_DIR" ]; then
        git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    fi

else
    log_warn "origin/arXiv-sync 分支不存在，可能 GitHub Action 还未运行"
    exit 0
fi

echo ""
log_info "🎉 全部完成！"
