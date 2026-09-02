# Rocket.Chat + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Prerequisites](#prerequisites)
- [Getting started](#getting-started)
- [Features](#features)
  - [Typical use cases](#typical-use-cases)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Backups](#backups)
- [Testing](#testing)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys **Rocket.Chat** behind **Traefik** with automatic **Let's Encrypt TLS**, backed by a **MongoDB replica set** (single-node, as Rocket.Chat requires), with a scheduled **mongodump backup container**. One `docker compose up` away from a self-hosted team-chat service at `https://your-domain`.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-rocket-chat-using-docker-compose/](https://www.heyvaldemar.com/install-rocket-chat-using-docker-compose/).

## Why this stack?

| Need | This stack | Manual install | Kubernetes | Other compose examples |
|------|-----------|----------------|------------|------------------------|
| Ready to deploy in <10 min | ✅ | ❌ hours of setup | ✅ if K8s is already running | Often |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME built-in | Manual certbot | Via cert-manager | Rare |
| MongoDB replica set auto-initialized | ✅ healthcheck bootstraps `rs0` | Manual `rs.initiate()` | Operator | Often missing — RC refuses to start |
| Scheduled DB backups + pruning | ✅ mongodump loop | Manual cron | External | Rare |
| Upstream images pinned by `sha256` digest | ✅ | N/A | Depends | Rare |
| Weekly pin-freshness check in CI | ✅ | N/A | Depends | Rare |
| CI-verified deployment on every push | ✅ | N/A | Varies | Rare |
| Credentials via env (never committed) | ✅ | N/A | K8s Secrets | Often committed plaintext |

Four moving parts (Traefik + Rocket.Chat + MongoDB + backups). No Kubernetes prerequisites, no manual certificate management, no manual replica-set ceremony.

## Prerequisites

Before you start, you need:

- **A Linux server** with a public IP. Tested on Ubuntu 22.04 LTS+ and Debian 12+. Local Mac/Windows works for dev; production is Linux.
- **Docker Engine 24+ and Docker Compose 2.20+.** Quick check: `docker version` and `docker compose version`.
- **A domain you control,** with two `A` records pointing at your server's public IP — one for Rocket.Chat (e.g. `rocketchat.example.com`), one for the Traefik dashboard (e.g. `traefik.rocketchat.example.com`). DNS must propagate before deploy or the Let's Encrypt TLS-ALPN challenge will fail.
- **Ports 80 and 443 open** on the server's firewall and not bound by another service.
- **~2 GB free RAM and 1 free CPU** for the running stack, plus disk for MongoDB data and backup retention.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose
cd rocketchat-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create rocketchat-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: ROCKETCHAT_HOSTNAME, ROCKETCHAT_URL, TRAEFIK_HOSTNAME,
#   TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.

# 4. Deploy
docker compose -f rocketchat-traefik-letsencrypt-docker-compose.yml -p rocketchat up -d
```

Within a couple of minutes `https://${ROCKETCHAT_HOSTNAME}` serves the Rocket.Chat setup wizard with a fresh Let's Encrypt certificate. The wizard creates the admin account and workspace on first visit.

### What success looks like

```bash
# All services healthy (Rocket.Chat takes ~2 minutes on first boot):
docker compose -f rocketchat-traefik-letsencrypt-docker-compose.yml -p rocketchat ps

# The API answers with the running version:
curl -fsS "https://${ROCKETCHAT_HOSTNAME}/api/info"
# Expected: {"info":{"version":"8.7.1"},...}

# Traefik issued a certificate:
docker compose -p rocketchat logs traefik | grep -i "adding certificate"

# First backup lands after BACKUP_INIT_SLEEP (default 30m):
docker compose -p rocketchat logs backups | tail -3
```

### Common first-deploy issues

- **Cert issuance fails.** DNS hasn't propagated or port 80 isn't reachable from the internet. Confirm with `dig +short ${ROCKETCHAT_HOSTNAME}` and `curl -I http://${ROCKETCHAT_HOSTNAME}` from outside the server.
- **`docker compose up` fails with `set in .env`.** A required variable is empty; the error names it.
- **`network rocketchat-network not found`.** Step 2 was skipped.
- **Rocket.Chat restarts waiting for MongoDB.** The replica set initializes via the mongodb healthcheck on first boot; give it up to a minute. `docker compose -p rocketchat logs mongodb` shows `rs.initiate` results.

### Apply `.env` or compose-file changes

```bash
docker compose -f rocketchat-traefik-letsencrypt-docker-compose.yml -p rocketchat up -d --force-recreate
```

## Features

- **Rocket.Chat** latest stable (8.7.1) — team chat, channels, DMs, apps, federation-capable.
- **MongoDB 7.0** single-node replica set, auto-initialized by the container healthcheck (Rocket.Chat requires oplog access). The 7.0 line is pinned deliberately: MongoDB 8.0 crashes on Linux kernels 6.19–7.0.13 ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)), which includes current distribution kernels.
- **Traefik v3** reverse proxy with automatic HTTP→HTTPS redirect and Let's Encrypt TLS-ALPN certificate issuance.
- **Basic-auth protected Traefik dashboard** on a separate hostname.
- **Scheduled `mongodump` backups** with configurable interval and retention.
- **Healthchecks** on every service with start-order dependencies.
- **Credentials required at deploy time** — compose fails fast if `.env` is incomplete.

### Typical use cases

- **Self-hosted Slack alternative** — teams that want chat history on their own hardware.
- **Community chat server** — public or invite-only workspaces without per-seat SaaS pricing.
- **Compliance-constrained messaging** — data residency requirements that rule out hosted chat.
- **Integration hub** — webhooks, bots, and the Rocket.Chat Apps marketplace against your own instance.

## Supply chain trust

This repository is a **deployment template**, not a custom Docker image. It orchestrates three upstream images:

- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image
- [`rocketchat/rocket.chat`](https://hub.docker.com/r/rocketchat/rocket.chat) — Rocket.Chat upstream
- [`mongo`](https://hub.docker.com/_/mongo) — MongoDB, Docker Hub official image

All three are pinned to `tag@sha256:<digest>` as interpolation defaults in the compose file's `x-images` block. Compose pulls by digest, not by tag — and `git pull` alone delivers the version combination this repository has tested, because the pins live in the tracked compose file rather than in your `.env`. Setting an `*_IMAGE_TAG` variable in `.env` overrides the default when you deliberately want a different version.

The weekly `check-pin-freshness` CI job re-resolves each pinned tag against its registry and compares the pinned Rocket.Chat and Traefik versions against the latest upstream releases — any drift fails the run and notifies the maintainer. CI's **Deployment Verification** workflow runs on every push, pull request, and every Monday at 06:00 UTC. GitHub Actions are pinned by commit SHA; Dependabot's `github-actions` ecosystem keeps those fresh.

## Production checklist

Before exposing this to real users, check every box:

- [ ] **Complete the setup wizard immediately after deploy.** Until the admin account exists, anyone reaching the URL can create it.
- [ ] **Disable open registration** (Admin → Accounts) unless the workspace is meant to be public.
- [ ] **Strong Traefik dashboard hash.** Regenerate `TRAEFIK_BASIC_AUTH` per deployment (command in `.env.example`).
- [ ] **Host-mount the backups volume** for disaster recovery — bind `DATA_BACKUPS_PATH` to a host path covered by your off-host backup solution.
- [ ] **Back up uploads too.** File uploads live in the `rocketchat-uploads` volume; `mongodump` covers only the database.
- [ ] **Verify Let's Encrypt cert issuance** in the Traefik logs on first start.
- [ ] **Plan your upgrade path.** Rocket.Chat supports rolling forward through minor versions; read the release notes before major bumps and back up first — there is no schema downgrade.

## Backups

The `backups` container runs `mongodump` of the `rocketchat` database on a loop: dump → prune → sleep. Each dump is a single gzip-compressed archive (`<name>-<timestamp>.archive.gz`) under `DATA_BACKUPS_PATH`; archives older than `DATA_BACKUP_PRUNE_DAYS` are pruned. All knobs (`BACKUP_INIT_SLEEP`, `BACKUP_INTERVAL`, `DATA_BACKUP_PRUNE_DAYS`, paths) are configured via `.env` with sensible compose-level defaults (30-minute warm-up, 24-hour interval, 7-day retention).

Each cycle logs `Database backup OK: <file> (<bytes> bytes)` or `Database backup FAILED` (the same for the data archive where there is one). A failed dump is kept as `<file>.failed` for diagnosis and never overwrites a good backup — grep the log for `FAILED` from your monitoring.

**Verify backups are running:**

```bash
docker compose -p rocketchat logs backups | tail -5
docker compose -p rocketchat exec backups ls /srv/rocketchat-mongodb/backups/
```

**Restore** with the interactive script (`chmod +x rocketchat-restore-database.sh` once): it lists the archives, stops Rocket.Chat, runs `mongorestore --drop --gzip --archive=<selected>`, and starts Rocket.Chat again.

```bash
./rocketchat-restore-database.sh
```

Backups made before v1.1.0 are directories, not archives; restore those with `mongorestore -h mongodb:27017 --db rocketchat --drop <backup-dir>/rocketchat` from inside the backups container.

**Off-host replication.** By default backups live in a named Docker volume — if the host dies, backups die with it. Bind-mount the backup path to a host directory covered by your off-host backup solution (restic, rclone, Borg, S3 sync).

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every Monday at 06:00 UTC:

1. **Lint** — actionlint on the workflow.
2. **Trivy scans** of all three pinned images (CRITICAL/HIGH, SARIF to the Security tab).
3. **Pin freshness** (weekly/manual) — digest drift against registries plus release-lag checks for Rocket.Chat and Traefik.
4. **Deploy-and-test** — boots the full stack with ephemeral credentials, waits for the MongoDB replica set to initialize and Rocket.Chat to report healthy, then requires `/api/info` to answer with the running version through Traefik before the run may pass.

A green run is the authoritative proof that the shipped configuration produces a working instance — not just started containers.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and the compose file fails fast on missing required variables.
- MongoDB listens only on the internal `rocketchat-network` — it is not exposed to the host or the internet.
- Upstream image digests are pinned; the weekly freshness job flags drift loudly.
- CI runs on every push and every Monday to catch upstream drift.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
