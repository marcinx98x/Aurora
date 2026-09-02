# Aurora Resolver Server

FastAPI + yt-dlp backend for the [Aurora Music](https://github.com/marcinx98x/Aurora) Android app. Handles YouTube search, playlist import, audio streaming (HTTP Range), Firebase sync, and optional lyrics.

**Docker Hub:** [`marcinx98x/aurora-server`](https://hub.docker.com/r/marcinx98x/aurora-server)

## Quick start (Docker Hub)

1. Copy the environment template and fill in secrets:

```bash
cp .env.example .env
# Edit .env — at minimum set AURORA_SECRET_KEY and FIREBASE_PROJECT_ID
```

2. Pull and run:

```bash
docker pull marcinx98x/aurora-server:latest

docker run -d --name aurora-server \
  -p 18000:8000 \
  --env-file .env \
  -v ./cache:/app/cache \
  -v ./data:/app/data \
  --restart unless-stopped \
  marcinx98x/aurora-server:latest
```

3. Verify:

```bash
curl http://localhost:18000/health
# {"ok":true}
```

## Docker Compose (Synology / VPS)

```bash
cp .env.example .env
# edit .env
docker compose pull
docker compose up -d
```

Compose uses `marcinx98x/aurora-server:latest` and falls back to a local build if the image is unavailable.

## Required environment variables

| Variable | Description |
|----------|-------------|
| `AURORA_SECRET_KEY` | Shared secret with the app (`x-api-key` header). Required for public deployment. |
| `FIREBASE_PROJECT_ID` | Firebase project ID for authenticated sync (`/sync`). |

## Optional environment variables

| Variable | Description |
|----------|-------------|
| `AURORA_CACHE_MAX_BYTES` | Stream cache limit (`unlimited`, `10GB`, `500MB`, …). |
| `YT_COOKIES_B64` | Base64-encoded YouTube cookies to reduce bot blocks. |
| `YOUTUBE_API_KEY` | YouTube Data API v3 key (optional subscription features). |
| `REGISTRY_URL` / `REGISTER_SECRET` | Vercel LAN registry auto-registration. |
| `PORT` | Host port advertised to the registry (not uvicorn; container listens on 8000). |

## Volumes

| Host path | Container path | Purpose |
|-----------|----------------|---------|
| `./cache` | `/app/cache` | Stream cache (SQLite + audio files) |
| `./data` | `/app/data` | User sync database (SQLite) |

## Build locally

```bash
docker build -t marcinx98x/aurora-server:latest .
docker push marcinx98x/aurora-server:latest   # requires Docker Hub login
```

## API endpoints

- `GET /health` — no auth
- `GET /search?q=...&limit=20`
- `GET /playlist?url=...`
- `GET /stream?v=VIDEO_ID` — audio with Range support
- `GET /sync` / `PUT /sync` — Firebase-authenticated user data

All endpoints except `/health` require `x-api-key: <AURORA_SECRET_KEY>` when the secret is configured.
