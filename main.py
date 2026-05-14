import html
import json
import re
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Set

import pytz

from src.api import ArxivClient
from src.category_match import resolve_category
from src.config import ConfigManager
from src.llm_scorer import LLMScorer
from src.logger import logger
from src.models import Config, Paper


class DailyPapers:
    """Simplified paper fetching system"""
    SEEN_IDS_FILE = "arxiv_seen_ids.tsv"
    
    def __init__(self, config_path: str = "config.yaml"):
        self.config: Config = ConfigManager(config_path).load()
        self.timezone = pytz.timezone(self.config.timezone)
        
        # Unified search terms = EDA + TCAD + base
        all_terms = (
            self.config.arxiv.eda_keywords
            + self.config.arxiv.tcad_keywords
        )
        
        self.arxiv_client = ArxivClient(
            max_results=self.config.arxiv.max_results,
            base_url=self.config.arxiv.base_url,
            categories=self.config.arxiv.categories,
            search_terms=all_terms
        )
        
        self.eda_kw_set = set(k.lower() for k in self.config.arxiv.eda_keywords)
        self.tcad_kw_set = set(k.lower() for k in self.config.arxiv.tcad_keywords)
        
        self.llm_scorer = self._init_llm_scorer()
    
    def _init_llm_scorer(self) -> LLMScorer:
        if self.config.llm.minimax and self.config.llm.minimax.get("api_key"):
            logger.info("Using MiniMax LLM scorer")
            return LLMScorer(config=self.config.llm.minimax, provider="minimax")
        else:
            logger.info("Using Google Gemini LLM scorer")
            return LLMScorer(config=self.config.llm.google, provider="google")
    
    def run(self) -> None:
        logger.info("=" * 50)
        logger.info("Starting DailyPapers")
        logger.info("=" * 50)
        
        try:
            current_date = datetime.now(self.timezone).strftime("%Y-%m-%d")
            current_date_short = datetime.now(self.timezone).strftime("%Y%m%d")
            
            # 1. Fetch papers
            all_papers = self.arxiv_client.fetch_papers()
            logger.info(f"Total papers fetched: {len(all_papers)}")
            
            # 1.1 Deduplicate
            seen_ids = self._load_seen_ids(current_date)
            all_papers = self._deduplicate_papers(all_papers, seen_ids)
            logger.info(f"Total papers after deduplication: {len(all_papers)}")
            
            # 2. LLM scoring
            scored_papers = self._score_papers(all_papers)
            
            # 3. Filter
            filtered_papers = [
                p for p in scored_papers
                if p.score >= self.config.llm.min_score
            ]
            filtered_papers = sorted(filtered_papers, key=lambda p: p.score, reverse=True)
            logger.info(f"Filtered: {len(all_papers)} → {len(filtered_papers)} papers")
            
            # 4. Classify EDA / TCAD
            for p in filtered_papers:
                self._classify_eda_tcad(p)
            
            # 5. Build per-paper JSON output for obsidian-import
            self._write_obsidian_import(filtered_papers, current_date, current_date_short)
            
            # 6. Write summary markdown
            self._write_daily_summary(filtered_papers, current_date)
            
            # 7. Persist seen IDs
            self._append_seen_ids(current_date, filtered_papers)
            
            logger.info("\n" + "=" * 50)
            logger.info("✅ DailyPapers completed successfully!")
            logger.info("=" * 50)
            
        except Exception as e:
            logger.error(f"❌ DailyPapers failed: {e}")
            traceback.print_exc()
            sys.exit(1)
    
    def _classify_eda_tcad(self, paper: Paper) -> None:
        """Classify paper as EDA, TCAD, or AI based on keyword matching."""
        text = (paper.title + " " + paper.abstract).lower()
        
        eda_hits = sum(1 for kw in self.eda_kw_set if kw in text)
        tcad_hits = sum(1 for kw in self.tcad_kw_set if kw in text)
        
        if eda_hits > tcad_hits and eda_hits > 0:
            paper.subcategory = "EDA"
        elif tcad_hits > eda_hits and tcad_hits > 0:
            paper.subcategory = "TCAD"
        else:
            paper.subcategory = "AI"
        
        paper.arxiv_id = self._normalize_arxiv_id(paper.link)

    def _write_obsidian_import(self, papers: List[Paper], date: str, date_short: str) -> None:
        """Write per-paper JSON files for each EDA/TCAD paper (skip AI for now)."""
        import_dir = Path("obsidian-import")
        import_dir.mkdir(exist_ok=True)
        
        # Group by subcategory
        for subcat in ["EDA", "TCAD"]:
            cat_dir = import_dir / subcat
            cat_dir.mkdir(exist_ok=True)
            
            date_dir = cat_dir / date_short
            date_dir.mkdir(exist_ok=True)
            
            subcat_papers = [p for p in papers if p.subcategory == subcat]
            
            logger.info(f"[{subcat}] {len(subcat_papers)} papers for {date}")
            
            for paper in subcat_papers:
                # Build safe directory name from title keywords
                safe_dir = self._make_safe_dirname(paper.title, paper.arxiv_id)
                paper_dir = date_dir / safe_dir
                paper_dir.mkdir(exist_ok=True)
                
                # Write JSON metadata (sync script will use this)
                meta = {
                    "title": paper.title,
                    "arxiv_id": paper.arxiv_id,
                    "link": paper.link,
                    "authors": paper.authors,
                    "date": date,
                    "date_short": date_short,
                    "score": paper.score,
                    "summary": paper.summary,
                    "reason": paper.reason,
                    "subcategory": subcat,
                    "category": paper.category,
                    "abstract": paper.abstract,
                }
                
                meta_file = paper_dir / "meta.json"
                with open(meta_file, "w", encoding="utf-8") as f:
                    json.dump(meta, f, ensure_ascii=False, indent=2)
                
                logger.info(f"  → {safe_dir}/ (score={paper.score:.0f})")
        
        # Write manifest
        manifest = {
            "date": date,
            "date_short": date_short,
            "papers": [
                {
                    "title": p.title,
                    "arxiv_id": p.arxiv_id,
                    "subcategory": p.subcategory,
                    "link": p.link,
                    "score": p.score,
                    "dir": self._make_safe_dirname(p.title, p.arxiv_id)
                }
                for p in papers if p.subcategory in ("EDA", "TCAD")
            ]
        }
        with open(import_dir / "manifest.json", "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
    
    def _make_safe_dirname(self, title: str, arxiv_id: str) -> str:
        """Make a safe directory name from title + arxiv id."""
        # Extract key terms from title
        words = re.findall(r'[A-Za-z]+(?:\d*[A-Za-z]+)*', title)
        # Filter short words and numbers
        key_words = [w for w in words if len(w) > 2 and not w.isdigit()][:6]
        
        if key_words:
            dirname = "_".join(key_words)
        else:
            dirname = arxiv_id.replace(".", "_")
        
        # Add short arxiv id suffix
        suffix = arxiv_id.replace(".", "_").replace("v", "-")
        return f"{dirname}_{suffix}"

    def _write_daily_summary(self, papers: List[Paper], date: str) -> None:
        """Write a summary markdown for the day."""
        eda = [p for p in papers if p.subcategory == "EDA"]
        tcad = [p for p in papers if p.subcategory == "TCAD"]
        ai = [p for p in papers if p.subcategory == "AI"]
        
        lines = [f"# 精选论文 - {date}\n"]
        lines.append(f"\n**EDA**: {len(eda)} 篇 | **TCAD**: {len(tcad)} 篇 | **AI**: {len(ai)} 篇\n")
        
        for group_name, grp in [("EDA", eda), ("TCAD", tcad), ("AI", ai)]:
            if not grp:
                continue
            lines.append(f"\n## {group_name}\n")
            for p in grp:
                lines.append(f"- **[{p.title}]({p.link})** (⭐{p.score:.0f}) - {p.summary[:80]}...")
        
        Path("papers").mkdir(exist_ok=True)
        with open(f"papers/{date}.md", "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        
        logger.info(f"Wrote papers/{date}.md")

    # ---- existing deduplication / seen-ids helpers (unchanged) ----
    
    def _load_seen_ids(self, current_date: str) -> Set[str]:
        papers_dir = Path("papers")
        papers_dir.mkdir(exist_ok=True)
        seen_file = papers_dir / self.SEEN_IDS_FILE

        if not seen_file.exists():
            self._bootstrap_seen_ids_index(seen_file)

        seen_ids: Set[str] = set()
        try:
            lines = seen_file.read_text(encoding="utf-8").splitlines()
        except OSError as e:
            logger.warning(f"Failed to read seen IDs file {seen_file}: {e}")
            return set()

        for line in lines:
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) != 2:
                continue
            record_date, arxiv_id = parts[0].strip(), parts[1].strip()
            if record_date and arxiv_id:
                seen_ids.add(arxiv_id)

        logger.info(f"Loaded {len(seen_ids)} IDs from {seen_file}")
        return seen_ids

    def _bootstrap_seen_ids_index(self, seen_file: Path) -> None:
        papers_dir = seen_file.parent
        records: Set[str] = set()

        for paper_file in papers_dir.glob("*.md"):
            try:
                content = paper_file.read_text(encoding="utf-8")
            except OSError:
                continue
            paper_ids = self._extract_arxiv_ids_from_markdown(content)
            for paper_id in paper_ids:
                records.add(f"{paper_file.stem}\t{paper_id}")

        sorted_records = sorted(records)
        try:
            with open(seen_file, "w", encoding="utf-8") as f:
                for record in sorted_records:
                    f.write(f"{record}\n")
        except OSError:
            return

        logger.info(f"Initialized {seen_file} with {len(sorted_records)} records")

    def _extract_arxiv_ids_from_markdown(self, content: str) -> Set[str]:
        paper_ids: Set[str] = set()
        for url in re.findall(r"https?://arxiv\.org/(?:abs|pdf)/[^\s\)\]<>\"']+", content):
            normalized_id = self._normalize_arxiv_id(url)
            if normalized_id:
                paper_ids.add(normalized_id)
        return paper_ids

    def _append_seen_ids(self, current_date: str, papers: List[Paper]) -> None:
        seen_file = Path("papers") / self.SEEN_IDS_FILE
        today_ids: Set[str] = set()
        for paper in papers:
            paper_id = self._normalize_arxiv_id(paper.link)
            if paper_id:
                today_ids.add(paper_id)

        if not today_ids:
            return

        existing_today: Set[str] = set()
        if seen_file.exists():
            try:
                lines = seen_file.read_text(encoding="utf-8").splitlines()
            except OSError:
                lines = []
            for line in lines:
                if not line.strip():
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2:
                    continue
                record_date, arxiv_id = parts[0].strip(), parts[1].strip()
                if record_date == current_date and arxiv_id:
                    existing_today.add(arxiv_id)

        new_ids = sorted(today_ids - existing_today)
        if not new_ids:
            return

        try:
            with open(seen_file, "a", encoding="utf-8") as f:
                for paper_id in new_ids:
                    f.write(f"{current_date}\t{paper_id}\n")
        except OSError:
            return

        logger.info(f"Appended {len(new_ids)} IDs to {seen_file}")

    @staticmethod
    def _normalize_arxiv_id(value: str) -> str:
        text = (value or "").strip()
        if not text:
            return ""
        match = re.search(r"arxiv\.org/(?:abs|pdf)/([^?#\s]+)", text)
        if match:
            text = match.group(1)
        text = text.replace(".pdf", "").strip()
        text = re.sub(r"^arxiv:", "", text, flags=re.IGNORECASE)
        text = re.sub(r"v\d+$", "", text, flags=re.IGNORECASE)
        return text.lower()

    def _paper_dedup_key(self, paper: Paper) -> str:
        arxiv_id = self._normalize_arxiv_id(paper.link)
        if arxiv_id:
            return arxiv_id
        return f"title:{paper.title.strip().lower()}"

    def _deduplicate_papers(self, papers: List[Paper], historical_ids: Set[str]) -> List[Paper]:
        fetched_unique_ids: Set[str] = set()
        for paper in papers:
            fetched_unique_ids.add(self._paper_dedup_key(paper))

        seen_ids = set(historical_ids)
        unique_papers: List[Paper] = []
        for paper in papers:
            dedup_key = self._paper_dedup_key(paper)
            if dedup_key in seen_ids:
                continue
            seen_ids.add(dedup_key)
            unique_papers.append(paper)

        logger.info(f"Dedup: {len(papers)} → {len(unique_papers)}")
        return unique_papers
    
    def _score_papers(self, papers: List[Paper]) -> List[Paper]:
        logger.info(f"Scoring {len(papers)} papers...")
        
        last_request_time = 0
        min_interval = self.config.llm.rate_limit_interval
        
        for i, paper in enumerate(papers, 1):
            current_time = time.time()
            elapsed = current_time - last_request_time
            if elapsed < min_interval and last_request_time > 0:
                wait_time = min_interval - elapsed
                time.sleep(wait_time)
            
            logger.info(f"[{i}/{len(papers)}] Scoring: {paper.title[:50]}...")
            
            score, summary, reason, category = self.llm_scorer.score_paper(
                paper.title,
                paper.abstract,
                self.config.keywords
            )
            
            last_request_time = time.time()
            
            paper.score = score
            paper.summary = summary
            paper.reason = reason
            paper.category = resolve_category(category, self.config.keywords)
        
        return papers


def main():
    app = DailyPapers()
    app.run()


if __name__ == "__main__":
    main()
