#!/bin/bash
# sync-to-obsidian.sh
# 完整流水线：下载PDF → 中文翻译 → 深度解析 → 同步到 Obsidian
#
# 用法: ./sync-to-obsidian.sh
# 建议配合 cron 使用，每天 08:00 执行

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

# ========== 0. 确认目录 ==========
if ! git -C "$OBSIDIAN_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    log_error "Obsidian 目录不是 git 仓库: $OBSIDIAN_DIR"
    exit 1
fi

# ========== 1. 拉取 arXiv-sync 分支 ==========
log_info "拉取 daily-papers 的 $ARXIV_SYNC_BRANCH 分支..."

cd "$DAILY_PAPERS_DIR"
git fetch origin arXiv-sync 2>/dev/null || true

if ! git rev-parse --verify origin/arXiv-sync > /dev/null 2>&1; then
    log_warn "origin/arXiv-sync 分支不存在，跳过"
    exit 0
fi

# 用 worktree 拉取
WORKTREE_DIR="$DAILY_PAPERS_DIR/.obsidian-sync-worktree"
rm -rf "$WORKTREE_DIR"
mkdir -p "$WORKTREE_DIR"

if ! git -C "$DAILY_PAPERS_DIR" worktree add -f "$WORKTREE_DIR" "origin/arXiv-sync" 2>/dev/null; then
    log_warn "worktree 不可用，使用直接 checkout"
    WORKTREE_DIR="$DAILY_PAPERS_DIR/.obsidian-temp-sync"
    rm -rf "$WORKTREE_DIR"
    mkdir -p "$WORKTREE_DIR"
    git -C "$DAILY_PAPERS_DIR" checkout origin/arXiv-sync -- . 2>/dev/null || {
        git -C "$DAILY_PAPERS_DIR" checkout origin/arXiv-sync:"$WORKTREE_DIR" 2>/dev/null || {
            log_warn "无法拉取 arXiv-sync 分支"
            exit 0
        }
    }
fi

IMPORT_DIR="$WORKTREE_DIR/obsidian-import"
if [ ! -d "$IMPORT_DIR" ]; then
    log_warn "没有找到 obsidian-import 目录，跳过同步"
    rm -rf "$WORKTREE_DIR"
    exit 0
fi

log_info "找到论文导入目录: $IMPORT_DIR"

# 读取 manifest
MANIFEST_FILE="$IMPORT_DIR/manifest.json"
if [ ! -f "$MANIFEST_FILE" ]; then
    log_warn "没有找到 manifest.json，跳过"
    rm -rf "$WORKTREE_DIR"
    exit 0
fi

# ========== 2. 切换到 Obsidian obsidian-sync 分支 ==========
log_info "切换到 Obsidian vault 的 $OBSIDIAN_SYNC_BRANCH 分支..."

cd "$OBSIDIAN_DIR"
git config pull.rebase true
git config rebase.autostash true

if git rev-parse --verify "$OBSIDIAN_SYNC_BRANCH" > /dev/null 2>&1; then
    git checkout "$OBSIDIAN_SYNC_BRANCH"
    git fetch origin
    git rebase origin/main 2>/dev/null || {
        log_warn "rebase 遇到冲突，中止并跳过"
        git rebase --abort || true
        rm -rf "$WORKTREE_DIR"
        exit 1
    }
else
    git checkout -b "$OBSIDIAN_SYNC_BRANCH"
fi

# ========== 3. 逐个 paper 处理 ==========
log_info "开始处理论文..."

# 构建路径
OBSIDIAN_DIR_ABS="/home/harrycrab/Obsidian"
WORKTREE_DIR_ABS="$WORKTREE_DIR"
IMPORT_DIR_ABS="$IMPORT_DIR"
MANIFEST_FILE_ABS="$MANIFEST_FILE"
SCRIPT_DIR_ABS="$SCRIPT_DIR"

# 解析 manifest 获取 paper 列表
PAPER_COUNT=$(python3 -c "
import json, sys
with open('$MANIFEST_FILE_ABS', 'r') as f:
    m = json.load(f)
print(len(m.get('papers', [])))
" 2>/dev/null || echo "0")

log_info "共 ${PAPER_COUNT} 篇论文待处理"

if [ "$PAPER_COUNT" -eq 0 ]; then
    log_info "没有论文需要处理，跳过"
    rm -rf "$WORKTREE_DIR"
    exit 0
fi

# 处理每篇论文
python3 << 'PYEOF'
import json, os, re, sys, time, urllib.request, subprocess
from datetime import datetime
from pathlib import Path

IMPORT_DIR = "/home/harrycrab/softwares/github/daily-papers/.obsidian-sync-worktree/obsidian-import"
OBSIDIAN_DIR = "/home/harrycrab/Obsidian"
SCRIPT_DIR = "/home/harrycrab/softwares/github/daily-papers"
MANIFEST_FILE = os.path.join(IMPORT_DIR, "manifest.json")

with open(MANIFEST_FILE, 'r', encoding='utf-8') as f:
    manifest = json.load(f)

date_short = manifest.get('date_short', datetime.now().strftime('%Y%m%d'))
date_long = manifest.get('date', datetime.now().strftime('%Y-%m-%d'))

with open(MANIFEST_FILE, 'r', encoding='utf-8') as f:
    manifest = json.load(f)

date_short = manifest.get('date_short', datetime.now().strftime('%Y%m%d'))
date_long = manifest.get('date', datetime.now().strftime('%Y-%m-%d'))

print(f"Processing {len(manifest['papers'])} papers for {date_long}")

# Load .env file - use hardcoded path since __file__ is not available in heredoc
ENV_FILE = "/home/harrycrab/softwares/github/daily-papers/.env"
if os.path.exists(ENV_FILE):
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, v = line.split('=', 1)
                os.environ[k.strip()] = v.strip()

MINIMAX_API_KEY = os.environ.get('MINIMAX_API_KEY', '')
print(f"[DEBUG] MINIMAX_API_KEY loaded: {'YES' if MINIMAX_API_KEY else 'NO'}")
GOOGLE_API_KEY = os.environ.get('GOOGLE_AI_API_KEY', '')

def llm_translate_and_analyze(title, abstract, api_key):
    """使用 LLM 翻译为中文并做深度解析"""
    if not api_key:
        return ("[翻译失败：未配置 API KEY]", "[解析失败：未配置 API KEY]")
    
    import urllib.request, json
    
    prompt = f"""你是一个专业的学术论文助手。请对以下论文进行两项任务：

1. **中文翻译**：将论文摘要翻译成流畅通顺的中文，保留专业术语的英文原文
2. **深度解析**：对论文进行深度分析，包括：
   - 研究背景与动机
   - 核心方法与技术贡献
   - 主要实验结果与结论
   - 创新点与局限性
   - 对该领域的潜在影响

论文标题：{title}
论文摘要：{abstract}

请用中文输出，格式如下：

## 中文翻译

[翻译内容]

## 深度解析

### 研究背景与动机
[内容]

### 核心方法与技术贡献
[内容]

### 主要实验结果与结论
[内容]

### 创新点与局限性
[内容]

### 对该领域的潜在影响
[内容]
"""
    
    # Try MiniMax first
    if MINIMAX_API_KEY:
        try:
            data = json.dumps({
                "model": "MiniMax-M2.7-highspeed",
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.3,
                "max_tokens": 4096
            }).encode('utf-8')
            req = urllib.request.Request(
                "https://api.minimax.chat/v1/chat/completions",
                data=data,
                headers={"Authorization": f"Bearer {MINIMAX_API_KEY}", "Content-Type": "application/json"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read().decode('utf-8'))
                return result['choices'][0]['message']['content'], ""
        except Exception as e:
            print(f"MiniMax error: {e}", file=sys.stderr)
    
    # Fallback to Google
    if GOOGLE_API_KEY:
        try:
            data = json.dumps({
                "contents": [{"parts": [{"text": prompt}]}]
            }).encode('utf-8')
            req = urllib.request.Request(
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=" + GOOGLE_API_KEY,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                result = json.loads(resp.read().decode('utf-8'))
                return result['candidates'][0]['content']['parts'][0]['text'], ""
        except Exception as e:
            print(f"Google error: {e}", file=sys.stderr)
    
    return "[翻译失败：API 调用失败]", "[解析失败：API 调用失败]"

def download_pdf(arxiv_id, output_path):
    """从 arXiv 下载 PDF"""
    # arXiv ID like 2301.12345v2 -> 2301.12345.pdf
    clean_id = re.sub(r'v\d+$', '', arxiv_id)
    pdf_url = f"https://arxiv.org/pdf/{clean_id}.pdf"
    
    try:
        req = urllib.request.Request(pdf_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            with open(output_path, 'wb') as f:
                f.write(resp.read())
        return True
    except Exception as e:
        print(f"PDF download error for {arxiv_id}: {e}", file=sys.stderr)
        return False

def make_safe_filename(title, max_len=80):
    """从标题生成安全文件名"""
    words = re.findall(r'[A-Za-z]+(?:\d*[A-Za-z]+)*', title)
    key_words = [w for w in words if len(w) > 2 and not w.isdigit()][:8]
    if key_words:
        return "_".join(key_words)
    return title[:30].replace(' ', '_')

for paper in manifest.get('papers', []):
    paper_dir_name = paper.get('dir', make_safe_filename(paper['title'], paper['arxiv_id']))
    subcat = paper.get('subcategory', 'AI')
    
    # Build paper directory path
    paper_base_dir = os.path.join(OBSIDIAN_DIR, '论文', subcat, 'arXiv', date_short, paper_dir_name)
    os.makedirs(paper_base_dir, exist_ok=True)
    
    meta_file = os.path.join(IMPORT_DIR, subcat, date_short, paper_dir_name, 'meta.json')
    
    if not os.path.exists(meta_file):
        # Try to find meta anywhere
        found_meta = None
        for root, dirs, files in os.walk(os.path.join(IMPORT_DIR, subcat, date_short)):
            if 'meta.json' in files:
                found_meta = os.path.join(root, 'meta.json')
                break
        if found_meta:
            meta_file = found_meta
        else:
            print(f"  ! meta.json not found for {paper_dir_name}, creating minimal")
            meta = {
                "title": paper['title'],
                "arxiv_id": paper['arxiv_id'],
                "link": paper['link'],
                "score": paper.get('score', 0),
            }
            with open(os.path.join(paper_base_dir, 'meta.json'), 'w', encoding='utf-8') as f:
                json.dump(meta, f, ensure_ascii=False, indent=2)
            continue
    
    with open(meta_file, 'r', encoding='utf-8') as f:
        meta = json.load(f)
    
    title = meta.get('title', paper['title'])
    arxiv_id = meta.get('arxiv_id', paper['arxiv_id'])
    abstract = meta.get('abstract', '')
    summary = meta.get('summary', '')
    authors = meta.get('authors', [])
    link = meta.get('link', paper['link'])
    score = meta.get('score', paper.get('score', 0))
    subcategory = meta.get('subcategory', subcat)
    
    safe_name = make_safe_filename(title, arxiv_id)
    date_prefix = date_long.replace('-', '')
    
    print(f"\n[{subcategory}] {safe_name}")
    
    # --- 1. Download PDF ---
    pdf_path = os.path.join(paper_base_dir, f"{date_prefix}_{safe_name}.pdf")
    if os.path.exists(pdf_path):
        print(f"  PDF already exists, skipping download")
    else:
        print(f"  Downloading PDF...")
        ok = download_pdf(arxiv_id, pdf_path)
        if ok:
            print(f"  ✅ PDF saved")
        else:
            print(f"  ⚠️  PDF download failed")
    
    # --- 2. Translate to Chinese ---
    trans_path = os.path.join(paper_base_dir, f"{date_prefix}_{safe_name}_中文翻译.md")
    if os.path.exists(trans_path):
        print(f"  中文翻译已存在，跳过")
        trans_content = None
    else:
        print(f"  Translating to Chinese...")
        trans_content, _ = llm_translate_and_analyze(title, abstract, MINIMAX_API_KEY or GOOGLE_API_KEY)
        trans_final = f"# {title}\n\n**arXiv**: [{arxiv_id}]({link})\n**作者**: {', '.join(authors[:3])}{' et al.' if len(authors) > 3 else ''}\n**评分**: ⭐ {score:.0f}/100\n**日期**: {date_long}\n\n---\n\n{trans_content}\n"
        with open(trans_path, 'w', encoding='utf-8') as f:
            f.write(trans_final)
        print(f"  ✅ 中文翻译 saved")
    
    # --- 3. Deep analysis ---
    analysis_path = os.path.join(paper_base_dir, f"{date_prefix}_{safe_name}_深度解析.md")
    if os.path.exists(analysis_path):
        print(f"  深度解析已存在，跳过")
    else:
        print(f"  Generating deep analysis...")
        _, analysis_content = llm_translate_and_analyze(title, abstract, MINIMAX_API_KEY or GOOGLE_API_KEY)
        if not analysis_content or analysis_content.startswith('['):
            analysis_content = f"# 深度解析\n\n**论文**: {title}\n**arXiv**: [{arxiv_id}]({link})\n**日期**: {date_long}\n\n> 深度解析需要 LLM API 支持。当前内容基于摘要自动生成。\n\n## 论文摘要\n\n{summary or abstract[:500]}\n\n## 基础评分\n\n- 评分: ⭐ {score:.0f}/100\n- 评分理由: {meta.get('reason', 'N/A')}\n"
        analysis_final = f"# {title} - 深度解析\n\n**arXiv**: [{arxiv_id}]({link})\n**作者**: {', '.join(authors[:3])}{' et al.' if len(authors) > 3 else ''}\n**日期**: {date_long}\n**子领域**: {subcategory}\n\n---\n\n{analysis_content}\n"
        with open(analysis_path, 'w', encoding='utf-8') as f:
            f.write(analysis_final)
        print(f"  ✅ 深度解析 saved")
    
    print(f"  → {paper_base_dir}")

print(f"\n✅ All papers processed!")
PYEOF

# ========== 4. 提交 obsidian-sync ==========
cd "$OBSIDIAN_DIR"
git add 论文/EDA/arXiv/ 论文/TCAD/arXiv/ 2>/dev/null || true

if git diff --quiet && git diff --staged --quiet; then
    log_info "没有新内容要提交"
else
    log_info "提交更改..."
    git commit -m "📚 sync: 同步论文 $(date +'%Y-%m-%d')"
    git push -u origin "$OBSIDIAN_SYNC_BRANCH"
    log_info "✅ obsidian-sync 已推送"
    
    # 合并到 main
    log_info "合并到 main..."
    git checkout main
    git fetch origin main
    if git merge --no-edit "$OBSIDIAN_SYNC_BRANCH" 2>/dev/null; then
        git push origin main
        log_info "✅ 已合并到 main"
    else
        log_warn "合并遇到冲突，手动解决"
        git merge --abort || true
    fi
fi

# ========== 5. 清理 ==========
cd "$DAILY_PAPERS_DIR"
rm -rf "$WORKTREE_DIR"
log_info "🎉 完成！"
