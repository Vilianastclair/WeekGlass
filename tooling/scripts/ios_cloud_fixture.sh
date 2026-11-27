#!/usr/bin/env bash
# Run the real service and its database on loopback for one simulator login.
set -eu -o pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/wgios.XXXXXXXX")"
pg="$(brew --prefix postgresql@17)/bin"
if [[ ! -x "$pg/initdb" ]]; then
  for bin in /opt/homebrew/opt/postgresql@*/bin; do
    if [[ -x "$bin/initdb" ]]; then pg="$bin"; break; fi
  done
fi
if [[ ! -x "$pg/initdb" ]]; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install postgresql@17
  pg="$(brew --prefix postgresql@17)/bin"
fi
ssl="$(brew --prefix openssl@3)/bin/openssl"
export PGHOST="$stage/socket" PGPORT=18760
mkdir -m 700 "$PGHOST"
api=
cleanup() {
  if [[ -n "$api" ]]; then kill "$api" 2>/dev/null || :; wait "$api" 2>/dev/null || :; fi
  if [[ -f "$stage/db/postmaster.pid" ]]; then "$pg/pg_ctl" -D "$stage/db" -m fast -w stop >/dev/null; fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
"$pg/initdb" --no-locale --encoding=UTF8 --auth-host=reject --auth-local=trust -D "$stage/db" >/dev/null
"$pg/pg_ctl" -D "$stage/db" -l "$stage/postgres.log" -o "-k '$PGHOST' -p $PGPORT -c listen_addresses=''" -w start
export WEEKGLASS_PUBLIC_ORIGIN=https://127.0.0.1:18766
export WEEKGLASS_SERVER_ID="$(uuidgen | tr 'A-Z' 'a-z')"
export DATABASE_URL="dbname=postgres host=$PGHOST port=$PGPORT" PYTHONPATH="$root/server/runtime"
export AUTH_SIGNING_KEY_FILE="$stage/server.key"
python3 -m venv "$stage/venv"
py="$stage/venv/bin/python"
"$py" -m pip -q install -r "$root/server/runtime/requirements.txt"
umask 077
openssl rand -hex 32 > "$AUTH_SIGNING_KEY_FILE"
openssl rand -hex 12 > "$stage/disposable-password"
"$py" -m weekglass_server.admin create-account iphonefixture --password-file "$stage/disposable-password" >/dev/null
export TEST_RUNNER_WG_FIXTURE_PASSWORD="$(cat "$stage/disposable-password")"
"$ssl" req -x509 -newkey rsa:2048 -noenc -days 1 -subj '/CN=WeekGlass disposable simulator CA' \
  -addext 'basicConstraints=critical,CA:true' -addext 'keyUsage=critical,keyCertSign' \
  -keyout "$stage/ca.key" -out "$stage/ca.pem" 2>/dev/null
"$ssl" req -new -newkey rsa:2048 -noenc -subj '/CN=127.0.0.1' -keyout "$stage/tls.key" -out "$stage/tls.csr" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:false\n' > "$stage/tls.ext"
"$ssl" x509 -req -days 1 -in "$stage/tls.csr" -CA "$stage/ca.pem" -CAkey "$stage/ca.key" -CAcreateserial \
  -extfile "$stage/tls.ext" -out "$stage/tls.pem" 2>/dev/null
"$py" -m uvicorn weekglass_server.main:app --host 127.0.0.1 --port 18766 --no-access-log \
  --ssl-keyfile "$stage/tls.key" --ssl-certfile "$stage/tls.pem" > "$stage/api.log" 2>&1 &
api=$!
for _ in {1..30}; do
  curl -fs --cacert "$stage/ca.pem" "$WEEKGLASS_PUBLIC_ORIGIN/healthz" >/dev/null && break
  kill -0 "$api" || { cat "$stage/api.log"; exit 1; }; sleep 1
done
curl -fsS --cacert "$stage/ca.pem" "$WEEKGLASS_PUBLIC_ORIGIN/healthz" >/dev/null
export WG_SIM_CA="$stage/ca.pem"
python3 -u "$root/tooling/scripts/test_ios_planner.py" --cloud
"$pg/psql" -d postgres -Atqc "select count(*) from devices where platform='ios' and display_name='WeekGlass iPhone'" | grep -qx 1
echo 'iPhone login, Keychain restore and device registration verified.'
