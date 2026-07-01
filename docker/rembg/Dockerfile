# Build próprio do rembg em modo servidor HTTP, pois a imagem oficial
# danielgatis/rembg só publica para linux/amd64 (sem suporte a arm64).
FROM python:3.11-slim

WORKDIR /rembg

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir "rembg[cpu,cli]"

RUN rembg d u2net

EXPOSE 7000

ENTRYPOINT ["rembg"]
CMD ["--help"]
