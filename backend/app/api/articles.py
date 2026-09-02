from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Article
from app.schemas import ArticleOut

router = APIRouter(prefix="/api/articles", tags=["articles"])


@router.get("", response_model=list[ArticleOut])
def list_articles(city_id: int | None = None, status: str | None = None,
                  limit: int = 100, db: Session = Depends(get_db)):
    q = db.query(Article).order_by(Article.importance_score.desc())
    if city_id:
        q = q.filter(Article.city_id == city_id)
    if status:
        q = q.filter(Article.status == status)
    return q.limit(limit).all()


@router.get("/{article_id}", response_model=ArticleOut)
def get_article(article_id: int, db: Session = Depends(get_db)):
    article = db.get(Article, article_id)
    if not article:
        raise HTTPException(404, "Artikel nicht gefunden")
    return article
