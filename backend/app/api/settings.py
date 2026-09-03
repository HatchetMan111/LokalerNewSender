"""API für Einstellungen, Quellen und Städte (CRUD über die Oberfläche)."""
from datetime import date as _date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import City, Setting, Source
from app.schemas import CityOut
from app.services import settings_svc
from app.services.ai import get_llm
from app.services.tts import get_tts

router = APIRouter(prefix="/api/settings", tags=["settings"])


@router.get("/registry")
def provider_registry(db: Session = Depends(get_db)):
    """Verfügbare Anbieter, Modelle, Stimmen, Styles – für dynamische UI."""
    return {
        "llm": {
            name: {"label": meta["label"], "needs": meta["needs"], "models": meta["models"]}
            for name, meta in settings_svc.LLM_PROVIDERS.items()
        },
        "tts": {
            name: {"label": meta["label"], "needs": meta["needs"], "voices": meta["voices"]}
            for name, meta in settings_svc.TTS_PROVIDERS.items()
        },
        "video": {
            "styles": settings_svc.VIDEO_STYLES,
            "resolutions": settings_svc.VIDEO_RESOLUTIONS,
            "backends": settings_svc.RENDERER_BACKENDS,
        },
        "current": {
            "llm_provider": settings_svc.llm_provider(db),
            "llm_model": settings_svc.llm_model(db),
            "llm_ready": settings_svc.llm_ready(db)[0],
            "tts_provider": settings_svc.tts_provider(db),
            "tts_ready": settings_svc.tts_ready(db)[0],
        },
    }


@router.post("/test/llm")
def test_llm(db: Session = Depends(get_db)):
    """Probiert den aktuell eingestellten LLM-Anbieter mit einem Mini-Prompt."""
    ready, msg = settings_svc.llm_ready(db)
    if not ready:
        return {"ok": False, "error": msg, "fallback": "mock"}
    llm = get_llm(db)
    try:
        if llm.name == "mock":
            # Mock erwartet ein JSON-Payload wie die Pipeline es sendet
            answer = llm.generate('{"headline": "Testsendung läuft", "summary": "Alle Systeme arbeiten normal.", "city": "Bad Mergentheim"}')
        else:
            answer = llm.generate(
                "Antworte mit genau einem Wort: OK",
                system="Du bist ein Test-Sender. Antworte minimal.",
            )
        return {"ok": True, "provider": llm.name, "model": llm.model, "answer": answer.strip()[:100]}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "provider": llm.name, "error": str(exc)[:300], "fallback": "mock"}


@router.post("/test/tts")
def test_tts(db: Session = Depends(get_db)):
    """Erzeugt eine 5-Sekunden-Testaufnahme mit der aktuellen Stimme."""
    import os
    import tempfile

    ready, msg = settings_svc.tts_ready(db)
    if not ready:
        return {"ok": False, "error": msg, "fallback": "edge"}
    tts = get_tts(db)
    voice = settings_svc.tts_voice(db)
    out = os.path.join(tempfile.gettempdir(), "tts-test.mp3")
    try:
        tts.synthesize("Dies ist ein Test der Sprecherstimme für lokale Nachrichten.", out, voice=voice)
        size = os.path.getsize(out)
        return {"ok": True, "provider": getattr(tts, "name", "?"), "voice": voice,
                "file_bytes": size, "file_url": f"/api/settings/test/tts/file"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "provider": getattr(tts, "name", "?"), "error": str(exc)[:300]}


@router.get("/test/tts/file")
def test_tts_file():
    import os
    import tempfile
    from fastapi.responses import FileResponse

    path = os.path.join(tempfile.gettempdir(), "tts-test.mp3")
    if not os.path.exists(path):
        raise HTTPException(404, "Erst POST /api/settings/test/tts ausführen")
    return FileResponse(path, media_type="audio/mpeg", filename="stimmen-test.mp3")


class SettingOut(BaseModel):
    key: str
    value: str
    category: Optional[str] = None
    label: Optional[str] = None
    description: Optional[str] = None


class SettingUpdate(BaseModel):
    value: str


@router.get("", response_model=list[SettingOut])
def list_settings(db: Session = Depends(get_db)):
    return db.query(Setting).order_by(Setting.category, Setting.key).all()


@router.patch("/{key}")
def update_setting(key: str, payload: SettingUpdate, db: Session = Depends(get_db)):
    row = db.get(Setting, key)
    if not row:
        raise HTTPException(404, f"Einstellung '{key}' nicht gefunden")
    row.value = payload.value
    db.commit()
    settings_svc.clear_cache()
    return {"key": key, "value": row.value, "updated": True}


# ---------------------------------------------------------------- Quellen ---
class SourceOut(BaseModel):
    id: int
    name: str
    type: Optional[str] = None
    rss_url: Optional[str] = None
    url: Optional[str] = None
    trust_score: int = 0
    active: bool = True

    class Config:
        from_attributes = True


class SourceCreate(BaseModel):
    name: str
    type: str = "rss"
    rss_url: Optional[str] = None
    url: Optional[str] = None
    trust_score: int = 50
    active: bool = True


router_sources = APIRouter(prefix="/api/sources", tags=["sources"])


@router_sources.get("", response_model=list[SourceOut])
def list_sources(db: Session = Depends(get_db)):
    return db.query(Source).order_by(Source.active.desc(), Source.name).all()


@router_sources.post("", response_model=SourceOut, status_code=201)
def create_source(payload: SourceCreate, db: Session = Depends(get_db)):
    if payload.type == "rss" and not payload.rss_url:
        raise HTTPException(422, "RSS-Quelle braucht eine rss_url")
    src = Source(**payload.model_dump())
    db.add(src)
    db.commit()
    db.refresh(src)
    return src


@router_sources.patch("/{source_id}", response_model=SourceOut)
def update_source(source_id: int, payload: SourceCreate, db: Session = Depends(get_db)):
    src = db.get(Source, source_id)
    if not src:
        raise HTTPException(404, "Quelle nicht gefunden")
    for field, value in payload.model_dump().items():
        setattr(src, field, value)
    db.commit()
    db.refresh(src)
    return src


@router_sources.delete("/{source_id}", status_code=204)
def delete_source(source_id: int, db: Session = Depends(get_db)):
    src = db.get(Source, source_id)
    if not src:
        raise HTTPException(404, "Quelle nicht gefunden")
    db.delete(src)
    db.commit()


# ------------------------------------------------------------------ Städte ---
router_cities = APIRouter(prefix="/api/cities", tags=["cities"])


class CityCreate(BaseModel):
    name: str
    state: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    radius_km: int = 25
    active: bool = True


@router_cities.get("", response_model=list[CityOut])
def list_cities(db: Session = Depends(get_db)):
    return db.query(City).filter(City.active.is_(True)).all()


@router_cities.post("", response_model=CityOut, status_code=201)
def create_city(payload: CityCreate, db: Session = Depends(get_db)):
    if db.query(City).filter(City.name == payload.name).first():
        raise HTTPException(409, "Stadt existiert bereits")
    city = City(**payload.model_dump())
    db.add(city)
    db.commit()
    db.refresh(city)
    return city


@router_cities.delete("/{city_id}")
def delete_city(city_id: int, db: Session = Depends(get_db)):
    """204 darf keinen Body haben – deshalb 200 mit Ergebnis-Flag."""
    city = db.get(City, city_id)
    if not city:
        raise HTTPException(404, "Stadt nicht gefunden")
    if city.episodes:  # type: ignore[attr-defined]
        city.active = False
        db.commit()
        return {"deactivated": True}
    db.delete(city)
    db.commit()
    return {"deleted": True}
