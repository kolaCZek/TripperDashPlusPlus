# syntax=docker/dockerfile:1.7
#
# fake_dash — TripperDash++ test harness
#
# Emulates the Royal Enfield Tripper TFT dashboard for iOS app development.
# Speaks K1G control-plane (UDP/2002) + RTP video sink (UDP/5000).
#
# Build:  docker compose build
# Run:    docker compose up
# Shell:  docker compose exec fake_dash sh
#

FROM python:3.12-slim AS base

# Runtime deps:
#   - ffmpeg: optional H.264 → MP4 conversion of captured streams
#   - tcpdump: optional packet inspection inside the container
# Keep image lean — anything purely dev-time stays out.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ffmpeg \
        tcpdump \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (cached layer) before copying source.
COPY pyproject.toml README.md ./
COPY fake_dash/ ./fake_dash/

RUN pip install --no-cache-dir -e .

# Captures volume mount point (host: ./captures)
RUN mkdir -p /captures /keys
VOLUME ["/captures", "/keys"]

# UDP/2002 = K1G control plane (RSA handshake, route card, joystick)
# UDP/5000 = RTP video sink (H.264 from iPhone)
EXPOSE 2002/udp 5000/udp

ENV FAKE_DASH_BIND=0.0.0.0 \
    FAKE_DASH_CAPTURES_DIR=/captures \
    FAKE_DASH_KEYS_DIR=/keys \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "-m", "fake_dash"]
CMD ["server"]
