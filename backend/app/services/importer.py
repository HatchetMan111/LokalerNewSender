"""News-Import aus RSS-Quellen + heuristische Analyse.

Heuristik bewertet Lokalität und Wichtigkeit; die KI-Schicht (LLM) kann
beides verfeinern, wenn ein Provider konfiguriert ist.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

import feedparser

from app.models import Article, City, Source
from app.services.ai import get_llm, parse_json_loose

log = logging.getLogger(__name__)

# Keyword-Gewichte für die Wichtigkeits-Heuristik
KEYWORD_WEIGHTS = {
    "brand": 40, "feuerwehr": 30, "unfall": 35, "polizei": 25,
    "tot": 30, "verletzt": 25, "evakuiert": 30,
    "gemeinderat": 25, "beschluss": 20, "bürgermeister": 25,
    "eröffnet": 20, "neubau": 15, "baustelle": 12, "sperrung": 20,
    "kita": 15, "schule": 15, "verkehr": 15, "bahn": 12,
    "fest": 8, "verein": 8, "sport": 10, "wetter": 5,
}


def score_importance(article: Article, city: City | None) -> int:
    text = f"{article.title} {article.original_text or ''}".lower()
    score = 0
    for kw, weight in KEYWORD_WEIGHTS.items():
        if kw in text:
            score = min(100, score + weight)
    if city and city.name.lower() in text:
        score = min(100, score + 30)
    return score


def looks_local(article: Article, city: City | None) -> bool:
    if not city:
        return True
    text = f"{article.title} {article.original_text or ''} {article.location or ''}".lower()
    return city.name.lower() in text


def import_from_sources(db, city: City) -> int:
    """Importiert Artikel aller aktiven RSS-Quellen. Return: Anzahl neuer Artikel."""
    count = 0
    sources = db.query(Source).filter(Source.active.is_(True), Source.type == "rss").all()
    for source in sources:
        if not source.rss_url:
            continue
        try:
            feed = feedparser.parse(source.rss_url)
        except Exception as exc:  # noqa: BLE001
            log.warning("RSS-Fehler bei %s: %s", source.name, exc)
            continue
        for entry in feed.entries[:30]:
            link = getattr(entry, "link", None)
            title = getattr(entry, "title", None)
            if not title:
                continue
            dup = db.query(Article).filter(Article.url == link).first()
            if dup:
                continue
            text = getattr(entry, "summary", "") or ""
            published = None
            if getattr(entry, "published_parsed", None):
                published = datetime(*entry.published_parsed[:6], tzinfo=timezone.utc)
            article = Article(
                source_id=source.id,
                title=title[:500],
                original_text=text,
                url=link,
                published_at=published,
                city_id=city.id,
                status="raw",
            )
            db.add(article)
            count += 1
    db.commit()
    return count


def analyze_articles(db, city: City, limit: int = 40) -> int:
    """Analysiert rohe Artikel: Lokalität, Wichtigkeit, Zusammenfassung."""
    llm = get_llm()
    articles = (
        db.query(Article)
        .filter(Article.city_id == city.id, Article.status == "raw")
        .order_by(Article.created_at.desc())
        .limit(limit)
        .all()
    )
    analyzed = 0
    for article in articles:
        if not looks_local(article, city):
            article.status = "rejected_nonlocal"
            continue
        article.importance_score = score_importance(article, city)
        if llm.name != "mock":
            try:
                raw = llm.generate(
                    json.dumps(
                        {
                            "task": "analyze",
                            "headline": article.title,
                            "text": (article.original_text or "")[:4000],
                        }
                    ),
                    system=(
                        "Antworte NUR mit JSON: {\"summary\": str, \"category\": str, "
                        "\"importance\": 0-100, \"topics\": [str]}. Auf Deutsch."
                    ),
                )
                data = parse_json_loose(raw)
                if data:
                    article.ai_summary = data.get("summary")
                    article.category = data.get("category", article.category)
                    article.importance_score = data.get("importance", article.importance_score)
                    article.ai_topics = {"topics": data.get("topics", [])}
            except Exception as exc:  # noqa: BLE001
                log.warning("LLM-Analyse fehlgeschlagen für Artikel %s: %s", article.id, exc)
        else:
            article.ai_summary = (article.original_text or article.title)[:400]
        article.status = "ai_processed"
        analyzed += 1
    db.commit()
    return analyzed
