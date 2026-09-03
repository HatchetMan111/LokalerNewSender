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

router = APIRouter(prefix="/api/settings", tags=["settings"])


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


@router_cities.delete("/{city_id}", status_code=204)
def delete_city(city_id: int, db: Session = Depends(get_db)):
    city = db.get(City, city_id)
    if not city:
        raise HTTPException(404, "Stadt nicht gefunden")
    if city.episodes:  # type: ignore[attr-defined]
        city.active = False
        db.commit()
        return {"deactivated": True}
    db.delete(city)
    db.commit()
