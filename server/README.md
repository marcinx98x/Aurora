# Aurora Resolver Server

FastAPI + yt-dlp backend for the [Aurora Music](https://github.com/marcinx98x/Aurora) Android app. Handles YouTube search, playlist import, audio streaming (HTTP Range), Firebase sync, and optional lyrics.

**Docker Hub:** [`marcinx98x/aurora-server`](https://hub.docker.com/r/marcinx98x/aurora-server)

## Quick start (Docker Compose)

Recommended for Synology NAS, VPS, and any Docker host. The image is built in CI and published to Docker Hub — you do **not** need Python or a local `Dockerfile` on the server.

1. Prepare the folder:

```bash
mkdir -p aurora && cd aurora
cp /path/to/repo/server/.env.example .env
cp /path/to/repo/server/docker-compose.yml .
mkdir -p cache data
```

2. Edit `.env` — minimum required:

```bash
AURORA_SECRET_KEY=your_shared_secret
FIREBASE_PROJECT_ID=your-firebase-project-id
```

3. Start:

```bash
docker compose pull
docker compose up -d
```

4. Verify:

```bash
curl http://localhost:18000/health
# {"ok":true}
```

## docker-compose.yml

```yaml
services:
  aurora:
    image: marcinx98x/aurora-server:latest
    pull_policy: always          # always fetch latest on restart
    ports:
      - "18000:8000"             # host:container
    env_file:
      - .env
    volumes:
      - ./cache:/app/cache       # stream cache
      - ./data:/app/data         # user sync DB
```

Uvicorn listens on **8000 inside the container** with **2 workers** (so `/stream` for the current track does not block a cache-hit for the next). Map any host port you like (18000 is the default in this repo).

## Synology NAS

1. Create a shared folder, e.g. `docker/aurora`.
2. Copy `docker-compose.yml` and `.env` into it.
3. Create subfolders `cache` and `data` (or let Docker create them on first run).
4. In **Container Manager** → Project → create from `docker-compose.yml`, or via SSH:

```bash
cd /volume1/docker/aurora
docker compose pull
docker compose up -d
```

5. Reverse proxy (Cloudflare, Synology reverse proxy) → `http://NAS_IP:18000`.

**Upgrade after a new Docker Hub release:**

```bash
docker compose pull
docker compose up -d
```

Your `.env`, `cache/`, and `data/` are preserved across updates.

## docker run (without Compose)

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

## Required environment variables

| Variable | Description |
|----------|-------------|
| `AURORA_SECRET_KEY` | Shared secret with the Android app (`x-api-key` header). Required for public deployment. |
| `FIREBASE_PROJECT_ID` | Firebase project ID for authenticated sync (`/sync`). |

## Optional environment variables

| Variable | Description |
|----------|-------------|
| `AURORA_CACHE_MAX_BYTES` | Stream cache limit (`unlimited`, `10GB`, `500MB`, …). |
| `YT_COOKIES_B64` | Base64-encoded YouTube cookies to reduce bot blocks on VPS/datacenter IPs. |
| `YOUTUBE_API_KEY` | YouTube Data API v3 key (optional; not needed for core search/stream). |
| `REGISTRY_URL` / `REGISTER_SECRET` | Vercel LAN registry auto-registration. |
| `PORT` | Port advertised to the LAN registry only — **not** uvicorn (container always uses 8000). |

Copy the full template from [`.env.example`](.env.example).

## Volumes

| Host path | Container path | Purpose |
|-----------|----------------|---------|
| `./cache` | `/app/cache` | Stream cache (SQLite + audio files) |
| `./data` | `/app/data` | Per-user sync database (SQLite) |

Do not delete these folders unless you intend to wipe cached streams or synced account data.

## CI: publish a new image

GitHub Actions workflow [`.github/workflows/docker-hub.yml`](../.github/workflows/docker-hub.yml) builds and pushes on every push to `main` that changes `server/**`.

Repository secret (one of):

| Secret | Value |
|--------|--------|
| `DOCKERHUB_TOKEN` | Docker Hub access token (Read & Write) |
| `MARCINX98X` | Same token (legacy fallback name) |

Manual trigger: GitHub → **Actions** → **Publish Docker Hub** → **Run workflow**.

## Build from source (developers)

Only needed if you change server code locally:

```bash
docker build -t marcinx98x/aurora-server:latest .
docker push marcinx98x/aurora-server:latest   # requires docker login
```

Or run without Docker:

```bash
python -m pip install -r requirements.txt
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --env-file .env
```

## API endpoints

- `GET /health` — no auth
- `GET /search?q=...&limit=20`
- `GET /playlist?url=...`
- `GET /stream?v=VIDEO_ID` — audio with Range support
- `GET /sync` / `PUT /sync` — Firebase-authenticated user data

All endpoints except `/health` require `x-api-key: <AURORA_SECRET_KEY>` when the secret is configured.
