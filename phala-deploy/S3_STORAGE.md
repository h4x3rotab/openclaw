# Encrypted S3 Storage for CVM

The CVM can use S3-compatible object storage (AWS S3, Cloudflare R2, MinIO, etc.) as its state backend. All data is encrypted client-side before upload using rclone's crypt overlay, so the storage provider never sees plaintext.

## Architecture

```
/data/openclaw  (FUSE mount — apps read/write normally)
  └── rclone crypt  (NaCl SecretBox encryption)
       └── S3 remote  (any S3-compatible provider)
```

The gateway and all tools interact with `/data/openclaw` as a normal directory. rclone transparently encrypts filenames and file contents before uploading to S3.

## How it works

1. **Boot**: the entrypoint generates an rclone config from environment variables
2. **Restore**: SQLite database files are pulled from S3 to local storage
3. **Mount**: rclone mounts the encrypted S3 bucket at `/data/openclaw` via FUSE
4. **Run**: the gateway starts and reads/writes the state dir normally
5. **Backup**: a background loop copies SQLite files to S3 every 60 seconds
6. **Symlinks**: a periodic job redirects `memory.db` files to local storage (safety measure for SQLite on FUSE)

Without `S3_BUCKET` set, the entrypoint skips all S3 logic and uses the local Docker volume as before.

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `S3_BUCKET` | Yes | — | Bucket name. Presence of this var enables S3 mode. |
| `S3_ENDPOINT` | Yes | — | S3 endpoint URL (e.g. `https://....r2.cloudflarestorage.com`) |
| `AWS_ACCESS_KEY_ID` | Yes | — | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | Yes | — | S3 secret key |
| `RCLONE_CRYPT_PASSWORD` | Yes | — | Encryption password (must be obscured — see below) |
| `S3_PROVIDER` | No | `Other` | rclone S3 provider hint (`Cloudflare`, `AWS`, `Minio`, etc.) |
| `S3_PREFIX` | No | `openclaw-state` | Key prefix inside the bucket |
| `S3_REGION` | No | `us-east-1` | S3 region |
| `RCLONE_CRYPT_PASSWORD2` | No | — | Optional salt for encryption |

## Setup

### 1. Create an S3 bucket

For Cloudflare R2:
- Dashboard > R2 > Create bucket
- Create an API token with **Object Read & Write** scoped to the bucket

### 2. Generate the encryption password

The crypt password must be obscured (not plaintext). Install rclone locally and run:

```sh
rclone obscure "$(head -c 32 /dev/urandom | base64)"
```

Save the output — this is your `RCLONE_CRYPT_PASSWORD`. If you lose it, the data on S3 is unrecoverable.

### 3. Create a secrets file

Save credentials to `phala-deploy/secrets/r2.env` (gitignored):

```env
S3_BUCKET=your-bucket
S3_ENDPOINT=https://your-account-id.r2.cloudflarestorage.com
S3_PROVIDER=Cloudflare
S3_REGION=auto
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
RCLONE_CRYPT_PASSWORD=your-obscured-password
```

### 4. Deploy

For local testing:

```sh
docker build -f phala-deploy/Dockerfile -t openclaw-cvm:test .
docker run -d --name openclaw --privileged \
  --env-file phala-deploy/secrets/r2.env \
  -e OPENCLAW_STATE_DIR=/data/openclaw \
  -e NODE_ENV=production \
  -p 18789:18789 \
  openclaw-cvm:test
```

For Phala Cloud, pass the env vars through the encrypted environment configuration (never put secrets in `docker-compose.yml`).

## Verification

Check mount status:

```sh
# Inside the container
mountpoint /data/openclaw        # should say "is a mountpoint"
ls /data/openclaw/                # should show openclaw.json, agents/, etc.
```

Check that S3 contents are encrypted:

```sh
rclone ls s3:your-bucket/openclaw-state/
# Filenames should be encrypted gibberish like "kh1v5oec8hqh01519qhuit8nc8"
```

Check SQLite backup:

```sh
ls /data/openclaw-local/sqlite/   # local copies of memory.db files
rclone ls s3-crypt:sqlite/        # backed-up copies on S3
```

## SQLite handling

SQLite databases use file locking that can be unreliable on FUSE mounts. As a safety measure:

- `memory.db` files are kept on local storage (`/data/openclaw-local/sqlite/`)
- Symlinks in the agent directories point to the local copies
- A background job copies local SQLite files to S3 every 60 seconds
- On boot, SQLite files are restored from S3 before the mount is created

This means memory data survives container restarts (restored from S3) with at most 60 seconds of data loss.

## VFS cache settings

The rclone mount uses these cache settings:

| Flag | Value | Effect |
|------|-------|--------|
| `--vfs-cache-mode` | `writes` | Cache writes locally, read through to S3 |
| `--vfs-write-back` | `5s` | Flush writes to S3 after 5s idle |
| `--dir-cache-time` | `30s` | Cache directory listings for 30s |
| `--vfs-cache-max-size` | `500M` | Limit local cache to 500MB |

## Disaster recovery

If the container is destroyed:

1. Create a new container with the same S3 env vars
2. The entrypoint restores SQLite files from S3, then mounts S3 as the state dir
3. All config, agent data, and memory is restored automatically

The only data at risk is SQLite writes from the last 60 seconds before destruction (the backup interval).

## Encryption details

rclone crypt uses:
- **NaCl SecretBox** (XSalsa20 + Poly1305) for file contents
- **EME** (ECB-Mix-ECB) wide-block encryption for filenames
- Standard filename encryption with encrypted directory names

The S3 provider sees only encrypted blobs with encrypted paths. Without the crypt password, the data is unrecoverable.
