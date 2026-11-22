#!/bin/bash
# An administrator with a local password, made on the previous release, still
# signs in after the upgrade and is still an administrator.
#
# Rocket.Chat 9.0.0 moved LDAP, SAML and Custom OAuth behind a Premium licence
# and removed several login providers; its release notes ask that at least one
# administrator can sign in with a local username and password before the
# update. That is the account this template's setup wizard creates. The
# upgrade drill runs `seed` against the previous release before stopping it:
# the first account registered on a fresh workspace, which Rocket.Chat makes
# an administrator. After the upgrade, `check` signs in with it through the
# REST API and requires the admin role. Both go through Traefik on
# 127.0.0.1:443.
#
#   tests/e2e-admin-survives.sh seed    # against the previous release
#   tests/e2e-admin-survives.sh check   # against the upgraded stack
#
# Requires: curl, python3, openssl, .env in the repository root. The account's
# password goes to $ADMIN_STATE (mode 600); no password or token is printed,
# and none reaches a command line.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mode="${1:-}"
case "$mode" in seed|check) ;; *) echo "usage: $0 seed|check" >&2; exit 2 ;; esac

[[ -f .env ]] || { echo "error: .env not found at $REPO_ROOT/.env" >&2; exit 2; }
set -o allexport
# shellcheck disable=SC1091
source .env
set +o allexport

HOST="${ROCKETCHAT_HOSTNAME:?ROCKETCHAT_HOSTNAME is not set in .env}"
# E2E_BASE_URL points it at Rocket.Chat directly (a run without Traefik).
if [[ -n "${E2E_BASE_URL:-}" ]]; then
  BASE="$E2E_BASE_URL"; RESOLVE=()
else
  BASE="https://$HOST"; RESOLVE=(--resolve "$HOST:443:127.0.0.1")
fi
STATE="${ADMIN_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rocketchat-admin.env}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

c() { curl -sk ${RESOLVE[@]+"${RESOLVE[@]}"} "$@"; }
# jget <path>: the value at a dotted path in the JSON on stdin; empty when absent.
jget() {
  python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].split("."):
        v = v[int(k)] if isinstance(v, list) else v.get(k)
except Exception:
    v = None
print("" if v is None else (" ".join(v) if isinstance(v, list) else v))' "$1"
}
ready() {
  local _
  for _ in $(seq 1 90); do
    c "$BASE/api/info" | grep -q '"version"' && return 0
    sleep 5
  done
  return 1
}
# login <user> <password file>: writes the session headers to $WORK/session;
# prints the HTTP status. The password goes in on stdin.
login() {
  local out code
  out="$(python3 -c 'import json, sys; print(json.dumps({"user": sys.argv[1], "password": open(sys.argv[2]).read().strip()}))' "$1" "$2" \
    | c -w '\n%{http_code}' -H "Content-Type: application/json" -d @- "$BASE/api/v1/login")"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  ( umask 077
    printf 'header = "X-Auth-Token: %s"\nheader = "X-User-Id: %s"\n' \
      "$(jget data.authToken <<<"$out")" "$(jget data.userId <<<"$out")" > "$WORK/session" )
  printf '%s' "$code"
}

if [[ "$mode" == seed ]]; then
  ready || { echo "seed: Rocket.Chat never answered /api/info through Traefik" >&2; exit 1; }
  user="drill-admin-$RANDOM"
  ( umask 077; openssl rand -base64 24 | tr -d '\n' > "$WORK/pass" )
  python3 -c 'import json, sys; print(json.dumps({"username": sys.argv[1], "email": sys.argv[1] + "@example.com", "name": "Drill Admin", "pass": open(sys.argv[2]).read().strip()}))' "$user" "$WORK/pass" \
    | c -H "Content-Type: application/json" -d @- "$BASE/api/v1/users.register" > "$WORK/reg"
  [[ "$(jget success < "$WORK/reg")" == True ]] \
    || { echo "seed: registering the first account failed: $(jget error < "$WORK/reg")" >&2; exit 1; }
  code="$(login "$user" "$WORK/pass")"
  [[ "$code" == 200 ]] || { echo "seed: the new account could not sign in: HTTP $code" >&2; exit 1; }
  roles="$(c -K "$WORK/session" "$BASE/api/v1/me" | jget roles)"
  [[ " $roles " == *" admin "* ]] || { echo "seed: the first account is not an administrator (roles: $roles)" >&2; exit 1; }
  ( umask 077; printf 'ADMIN_USER=%s\nADMIN_PASS=%s\n' "$user" "$(cat "$WORK/pass")" > "$STATE" )
  echo "seed: '$user' registered on $(c "$BASE/api/info" | jget version), signs in with a local password, roles: $roles"
  exit 0
fi

[[ -s "$STATE" ]] || { echo "check: no seed state at $STATE; seed did not run" >&2; exit 1; }
user="$(sed -n 's/^ADMIN_USER=//p' "$STATE")"
( umask 077; sed -n 's/^ADMIN_PASS=//p' "$STATE" > "$WORK/pass" )
[[ -n "$user" && -s "$WORK/pass" ]] || { echo "check: the seed state is incomplete" >&2; exit 1; }
ready || { echo "check: Rocket.Chat never answered /api/info through Traefik" >&2; exit 1; }
code="$(login "$user" "$WORK/pass")"
[[ "$code" == 200 ]] || { echo "check: '$user', made before the upgrade, can no longer sign in with its local password: HTTP $code" >&2; exit 1; }
roles="$(c -K "$WORK/session" "$BASE/api/v1/me" | jget roles)"
[[ " $roles " == *" admin "* ]] || { echo "check: '$user' signs in but is no longer an administrator (roles: $roles)" >&2; exit 1; }
anon="$(c -o /dev/null -w '%{http_code}' "$BASE/api/v1/me")"
echo "check: '$user', made before the upgrade, signs in on $(c "$BASE/api/info" | jget version) with its local password; roles: $roles; /api/v1/me without a session: HTTP $anon"
