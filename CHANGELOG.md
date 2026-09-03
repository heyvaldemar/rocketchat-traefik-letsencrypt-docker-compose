# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.4.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

## [1.3.0] - 2026-09-02

### Added

- **Resource limits on every service, as `.env`-overridable defaults.**
  Each service now carries memory and CPU limits plus reservations
  (`<SERVICE>_MEMORY_LIMIT`, `_CPU_LIMIT`, `_MEMORY_RESERVATION`,
  `_CPU_RESERVATION`, defaults listed in `.env.example`). Set any of
  them in `.env` and the override survives every `git pull`. The
  defaults are what CI boots the stack under, so they are known to be
  enough for a fresh install; raise a limit if a service is OOM-killed
  under your real load (`docker inspect` shows `OOMKilled=true`).

## [1.2.0] - 2026-09-02

### Added

- **`tests/e2e-backup-restore.sh`**: seven end-to-end scenarios against
  the live stack, run by CI on every push and by you locally: the
  required-variable guard fires, a backup is produced, it is a readable
  archive with real dump content (and a readable data `tar.gz` where the
  stack has one), a database outage is reported as `FAILED`, **restore
  genuinely replaces database state** (a marker row inserted after the
  baseline backup is gone after restoring it), and pruning removes only
  old files.

## [1.1.0] - 2026-09-02

### Fixed

- **A failed database dump no longer produces a silent, corrupt backup.**
  The old loop piped the dump into `gzip` and only checked `gzip`'s exit
  status, so a dump that failed halfway (database down, wrong password,
  disk full) still left a small `.gz` that looked like a backup. The loop
  now runs with `pipefail`, logs `Database backup OK: <file> (<bytes>
  bytes)` or `Database backup FAILED` per cycle, keeps a failed dump as
  `<file>.failed` for diagnosis, and prunes only its own files. Retention
  set to `0` disables pruning instead of deleting everything.

### Changed

- **Dumps are now single gzip archives** (`mongodump --archive --gzip`)
  instead of directory trees, so a backup is one file to copy, verify,
  and prune. Directory backups from earlier versions still restore with
  plain `mongorestore <dir>/rocketchat`.

### Added

- `rocketchat-restore-database.sh`: interactive restore: lists archives,
  stops Rocket.Chat, `mongorestore --drop --gzip --archive`, starts it.
- CI now waits for the first backup cycle and proves the produced
  archive is readable (plus a readable `tar.gz` for the data backup where
  the stack has one).

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Security

- **Rocket.Chat bumped 8.1.0 → 8.7.1**, **Traefik bumped 3.2 → 3.7**:
  Traefik 3.2's Docker client cannot talk to Docker Engine 29 (provider
  retry loop, silent 404s on current hosts). MongoDB moves to the official
  `mongo:7.0` image, digest-pinned. Two deliberate choices here: the
  previously used `mongodb/mongodb-community-server:8.0` image cannot run
  on Linux kernels 6.19+, and MongoDB 8.0 itself crashes on kernels
  6.19-7.0.13 (tcmalloc rseq bug, SERVER-121912): the 7.0 line is
  unaffected and officially supported by Rocket.Chat.
- **All three images pinned by `tag@sha256:digest`.**
- `.env` untracked and gitignored; `.env.example` documents every value,
  and compose fails fast via `${VAR:?}` when required values are unset.

### Changed

- **Image pins live in the compose file as interpolation defaults**
  (`x-images` block): `git pull` alone delivers the tested version
  combination; `.env` carries only hostnames and deliberate overrides.
- Backup-loop variables escaped (`$$VAR`) so the container shell resolves
  them at runtime from compose-level defaults; the minimal `.env` is
  hostnames plus Traefik credentials only.
- README rebuilt to the fleet evaluator-first structure.

### Added

- **Deployment Verification workflow**: actionlint; Trivy scans of all
  three pinned images; weekly `check-pin-freshness` (digest drift +
  Rocket.Chat and Traefik release lag); deploy-and-test that boots the
  full stack with ephemeral credentials, waits for the MongoDB replica set
  and Rocket.Chat healthcheck, and requires `/api/info` to answer with the
  running version through Traefik.

[Unreleased]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
