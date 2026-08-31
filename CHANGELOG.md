# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-08-31

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Security

- **Rocket.Chat bumped 8.1.0 → 8.7.1**, **Traefik bumped 3.2 → 3.7** —
  Traefik 3.2's Docker client cannot talk to Docker Engine 29 (provider
  retry loop, silent 404s on current hosts). MongoDB moves to the official
  `mongo:7.0` image, digest-pinned. Two deliberate choices here: the
  previously used `mongodb/mongodb-community-server:8.0` image cannot run
  on Linux kernels 6.19+, and MongoDB 8.0 itself crashes on kernels
  6.19–7.0.13 (tcmalloc rseq bug, SERVER-121912) — the 7.0 line is
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

[Unreleased]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
