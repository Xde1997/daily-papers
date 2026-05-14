from datetime import datetime
from typing import List, Optional
from pydantic import BaseModel, ConfigDict


class Paper(BaseModel):
    model_config = ConfigDict(json_encoders={datetime: lambda v: v.isoformat()})
    
    title: str
    authors: List[str]
    abstract: str
    link: str
    tags: List[str]
    comment: str
    date: datetime
    
    score: float = 0.0
    summary: str = ""
    reason: str = ""
    category: str = ""
    subcategory: str = ""   # EDA / TCAD / AI
    arxiv_id: str = ""


class Config(BaseModel):
    keywords: List[str]
    arxiv: 'ArxivConfig'
    llm: 'LLMConfig'
    timezone: str = "Asia/Shanghai"


class ArxivConfig(BaseModel):
    max_results: int = 500
    base_url: str = "https://export.arxiv.org/api/query"
    categories: List[str] = []
    eda_keywords: List[str] = []
    tcad_keywords: List[str] = []


class LLMConfig(BaseModel):
    min_score: float = 70.0
    max_papers_per_keyword: int = 5
    rate_limit_interval: float = 4.1
    google: dict = {}
    minimax: dict = {}
