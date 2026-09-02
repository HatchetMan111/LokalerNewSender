import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import articles, cities, episodes, pipeline
from app.services.storage import ensure_dirs

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

app = FastAPI(title="Local News Platform", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(cities.router)
app.include_router(articles.router)
app.include_router(episodes.router)
app.include_router(pipeline.router)


@app.on_event("startup")
def startup():
    ensure_dirs()


@app.get("/api/health")
def health():
    return {"status": "ok", "service": "local-news-backend"}
