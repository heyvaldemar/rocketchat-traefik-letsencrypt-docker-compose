#!/bin/bash
# Update this deployment to the latest release of the template.
#
# Moves between RELEASE TAGS, never to an arbitrary commit: a tag is a
# combination the repository's CI has booted and smoke-tested. Refuses to
# cross a major version unattended, refuses to run over local changes,
# names any new required variable before anything has moved, and, when the
# release moves MongoDB to a new version line, first checks that this host
# can run it and backs the database up.
#
#   ./update.sh              update to the latest release
#   ./update.sh --dry-run    say what would happen
#   ./update.sh --allow-major   cross a major version, after reading its notes
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="rocketchat-traefik-letsencrypt-docker-compose.yml"
PROJECT="${COMPOSE_PROJECT_NAME:-rocketchat}"
DRY_RUN=false
ALLOW_MAJOR=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --allow-major) ALLOW_MAJOR=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Local changes would be carried across the checkout or block it half way.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "local changes present — commit or stash them first, nothing updated" >&2
  exit 1
fi

# docker compose reads .env last, after the checkout. A .env this user
# cannot read (a copy restored without -p comes back root:root 0600) would
# stop it there, with the tree already on the new tag, and would make every
# required variable below read as "not set". Name the file and stop first.
if [ -e .env ] && [ ! -r .env ]; then
  echo ".env is not readable by $(id -un) ($(stat -c '%A %U:%G' .env 2>/dev/null || stat -f '%Sp %Su:%Sg' .env)) — fix its ownership, nothing updated" >&2
  exit 1
fi

git fetch --tags --quiet origin

latest="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [ -z "$latest" ]; then
  echo "no release tags found — nothing to update to" >&2
  exit 1
fi

current="$(git describe --tags --abbrev=0 2>/dev/null || echo 'v0.0.0')"
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$latest^{commit}")" ]; then
  echo "already on $latest"
  exit 0
fi

# A major version is where contracts change. Its release notes are the
# decision; this script will not make it for you.
cur_major="${current#v}"; cur_major="${cur_major%%.*}"
new_major="${latest#v}";  new_major="${new_major%%.*}"
if [ "$new_major" != "$cur_major" ] && [ "$ALLOW_MAJOR" != "true" ]; then
  echo "refusing to cross a major version unattended: $current -> $latest" >&2
  echo "read the release notes, then re-run with --allow-major:" >&2
  echo "  https://github.com/heyvaldemar/rocketchat-traefik-letsencrypt-docker-compose/releases/tag/$latest" >&2
  exit 3
fi

# NEW VARIABLES SINCE YOUR VERSION. An update can add a required variable,
# and `docker compose up` would then stop with a message naming it - after
# the checkout, with the tree already on the new tag. Better to say so here,
# before anything has moved. Names only, never values.
if [ -n "${COMPOSE_FILES+x}" ]; then _files=("${COMPOSE_FILES[@]}"); else _files=("$COMPOSE_FILE"); fi
_new="$(comm -13 <(git show "HEAD:.env.example" 2>/dev/null | grep -oE '^[A-Z0-9_]+=' | tr -d '=' | sort -u) \
               <(git show "$latest:.env.example" 2>/dev/null | grep -oE '^[A-Z0-9_]+=' | tr -d '=' | sort -u))"
if [ -n "$_new" ]; then
  echo "new variables in .env.example since $current:"
  while IFS= read -r _k; do echo "  $_k"; done <<<"$_new"
  _required=""
  for _f in "${_files[@]}"; do
    _required="$_required $(git show "$latest:$_f" 2>/dev/null | grep -oE '\$\{[A-Z0-9_]+:\?' | sed -E 's/^\$\{//; s/:\?$//' | tr '\n' ' ' || true)"
  done
  _missing=""
  for _k in $_new; do
    case " $_required " in *" $_k "*) grep -qE "^${_k}=." .env 2>/dev/null || _missing="$_missing $_k" ;; esac
  done
  if [ -n "$_missing" ]; then
    echo "required in $latest and not set in .env:$_missing" >&2
    echo "see .env.example at $latest for what each one is; nothing was changed" >&2
    [ "$DRY_RUN" = "true" ] || exit 4
  fi
fi

# MONGODB VERSION LINE. A release can move MongoDB to its next line (7.0 to
# 8.0), and three things then decide whether the database comes back:
#  - mongod opens a data directory only when its featureCompatibilityVersion
#    is that line or the one before. Data a 6.0 server wrote keeps 6.0 under
#    7.0 until someone raises it, and 8.0 will not open it.
#  - MongoDB 8 does not start at all on Linux kernels 6.19.0 to 7.0.13
#    (SERVER-121912); on those, even `mongod --version` exits.
#  - once the new line raises the data's version, the old one cannot open it.
# So before anything moves: the new image's mongod runs once on this host,
# the running database's featureCompatibilityVersion is brought up to its
# own line if it is lower, and a backup is written next to the scheduled
# ones. The new line then runs on the version the data already has, so the
# old image still opens it, and going back stays a checkout.
refuse() { echo "$1 — nothing updated" >&2; exit 5; }
svc_id() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -n 1 || true; }
_mdb="$(svc_id mongodb)"
_moved=""
if [ -n "$_mdb" ]; then
  _next="$(mktemp ./.update-next.XXXXXX)"
  git show "$latest:$COMPOSE_FILE" > "$_next"
  _img="$(docker compose -f "$_next" --project-directory . -p "$PROJECT" config mongodb 2>/dev/null | sed -nE 's/^ +image: +//p' | head -n 1 || true)"
  rm -f "$_next"
  if [ -z "$_img" ]; then
    [ "$DRY_RUN" = "true" ] || refuse "cannot read the MongoDB image $latest runs (docker compose config fails on it)"
    echo "cannot read the MongoDB image $latest runs; the MongoDB checks are skipped in this dry run"
  else
    _cur="$(docker exec "$_mdb" mongod --version 2>/dev/null | sed -nE 's/^db version v([0-9]+\.[0-9]+).*/\1/p')"
    docker pull -q "$_img" >/dev/null || refuse "cannot pull $_img"
    if ! _probe="$(docker run --rm --entrypoint mongod "$_img" --version 2>&1)"; then
      _why="$(sed -nE 's/.*"msg":"([^"]*)".*/\1/p' <<<"$_probe" | head -n 1)"; _why="${_why%.}"
      refuse "MongoDB in $latest cannot run on this host: ${_why:-$(tail -n 1 <<<"$_probe")}. To stay on ${_cur:-the current line} past this release, set ROCKETCHAT_MONGODB_IMAGE_VERSION=${_cur:-<line>} in .env"
    fi
    _new="$(sed -nE 's/^db version v([0-9]+\.[0-9]+).*/\1/p' <<<"$_probe")"
    if [ -n "$_cur" ] && [ -n "$_new" ] && [ "$_cur" != "$_new" ]; then
      echo "MongoDB moves from $_cur to $_new, and its mongod starts on this host"
      _fcv="$(docker exec "$_mdb" mongosh --quiet --eval 'const f = db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion; print(f.version + (f.targetVersion ? " to " + f.targetVersion : ""))' 2>/dev/null)" \
        || refuse "the running MongoDB does not answer, and its data is about to move from $_cur to $_new"
      if [ "$_fcv" != "$_cur" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          echo "featureCompatibilityVersion is $_fcv: would raise it to $_cur, which $_new requires"
        else
          if ! _out="$(docker exec "$_mdb" mongosh --quiet --eval "let r; try { r = db.adminCommand({setFeatureCompatibilityVersion: '$_cur', confirm: true}); } catch (e) { if (!/confirm/.test(e.message)) throw e; r = db.adminCommand({setFeatureCompatibilityVersion: '$_cur'}); } if (!r.ok) { print(r.errmsg); quit(1); }" 2>&1)"; then
            echo "$_out" >&2
            refuse "featureCompatibilityVersion is $_fcv and could not be raised to $_cur, which $_new requires"
          fi
          echo "featureCompatibilityVersion raised from $_fcv to $_cur"
        fi
      else
        echo "featureCompatibilityVersion is $_cur, as $_new requires"
      fi
      _bkp="$(svc_id backups)"
      [ -n "$_bkp" ] || refuse "the backups container is not running, and the data is about to move from $_cur to $_new: start it first"
      if [ "$DRY_RUN" = "true" ]; then
        echo "would write a backup to $(docker exec "$_bkp" printenv DATA_BACKUPS_PATH) first"
      else
        _file="$(docker exec "$_bkp" bash -c 'set -o pipefail; f="$DATA_BACKUPS_PATH/$DATA_BACKUP_NAME-$(date +%Y-%m-%d_%H-%M)-before-mongodb-'"$_new"'.archive.gz"; mongodump --quiet -h mongodb:27017 --db rocketchat --archive="$f.partial" --gzip && mv "$f.partial" "$f" && echo "$f"')" \
          || refuse "the backup before the move from $_cur to $_new failed"
        echo "backup written: $_file"
      fi
      _moved="$_cur"
    fi
  fi
fi

echo "updating $current -> $latest"
if [ "$DRY_RUN" = "true" ]; then
  git log --oneline "HEAD..$latest^{commit}" | sed 's/^/  would apply: /'
  echo "dry run — nothing changed"
  exit 0
fi

git checkout -q "$latest"
_up=0
docker compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d --remove-orphans || _up=$?
if [ -n "$_moved" ]; then
  # compose has already waited for a healthy database when it failed on one
  _ok=""
  for _ in $(seq 1 "$([ "$_up" = 0 ] && echo 36 || echo 1)"); do
    _c="$(svc_id mongodb)"
    if [ -n "$_c" ] && [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$_c")" = healthy ]; then _ok=1; break; fi
    sleep 5
  done
  if [ -z "$_ok" ]; then
    echo "MongoDB $_new is not healthy on $latest. Its data still carries featureCompatibilityVersion $_moved, so the previous release opens it:" >&2
    echo "  git checkout -q $current && docker compose -f $COMPOSE_FILE -p $PROJECT up -d" >&2
    echo "The backup taken before the move is $_file" >&2
    exit 6
  fi
  echo "MongoDB $_new is up, on featureCompatibilityVersion $_moved; going back is still a checkout of $current"
fi
[ "$_up" = 0 ] || exit "$_up"
echo "now on $latest"
