FROM python:3.12-slim

# ffmpeg für Rendering, Fonts für FFmpeg drawtext (Lower Thirds/Titelkarten)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg curl fonts-dejavu-core fontconfig \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8000
