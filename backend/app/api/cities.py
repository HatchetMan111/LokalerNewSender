from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import City
from app.schemas import CityOut

router = APIRouter(prefix="/api/cities", tags=["cities"])


@router.get("", response_model=list[CityOut])
def list_cities(db: Session = Depends(get_db)):
    return db.query(City).filter(City.active.is_(True)).all()
