#!/usr/bin/env bash
# fake-ipad.sh — drive the full OrgPad protocol against a live org-pad server.
# pair -> poll(long) -> result (or --cancel). CI-able, no Apple hardware.
# Usage: fake-ipad.sh [--host H] [--port P] [--code NNNNNN] [--cancel]
#                     [--png FILE] [--drawing FILE] [--poll-timeout S]
# Exit: 0 success, 2 pairing failed, 3 no session, 4 upload failed.
set -euo pipefail

HOST="127.0.0.1"; PORT="8777"; CODE="123456"; DO_CANCEL=0; POLL_TIMEOUT=60
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PNG="$SCRIPT_DIR/tests/fixtures/fixture.png"
DRAWING="$SCRIPT_DIR/tests/fixtures/fixture.drawing"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --code) CODE="$2"; shift 2;;
    --cancel) DO_CANCEL=1; shift;;
    --png) PNG="$2"; shift 2;;
    --drawing) DRAWING="$2"; shift 2;;
    --poll-timeout) POLL_TIMEOUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done

BASE="http://$HOST:$PORT"

# Extract a top-level JSON string value without jq: json_str '{"token":"abc"}' token -> abc
json_str() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

echo "==> [1/3] pair: POST $BASE/pair code=$CODE"
PAIR_JSON="$(curl -sS -X POST "$BASE/pair" -H 'Content-Type: application/json' --data "{\"code\":\"$CODE\"}")"
TOKEN="$(json_str "$PAIR_JSON" token)"
if [ -z "$TOKEN" ]; then echo "    pairing failed: $PAIR_JSON" >&2; exit 2; fi
echo "    token=${TOKEN:0:8}..."

echo "==> [2/3] poll: GET $BASE/session (long-poll, up to ${POLL_TIMEOUT}s)"
SID=""; DEADLINE=$(( $(date +%s) + POLL_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  RESP="$(curl -sS -w $'\n%{http_code}' -X GET "$BASE/session" -H "X-OrgPad-Token: $TOKEN")"
  STATUS="${RESP##*$'\n'}"; BODY="${RESP%$'\n'*}"
  if [ "$STATUS" = "200" ]; then
    SID="$(json_str "$BODY" session_id)"
    echo "    got session_id=$SID mode=$(json_str "$BODY" mode)"; break
  elif [ "$STATUS" = "204" ]; then continue
  else echo "    unexpected poll status=$STATUS body=$BODY" >&2; exit 3; fi
done
if [ -z "$SID" ]; then echo "    no session within ${POLL_TIMEOUT}s" >&2; exit 3; fi

if [ "$DO_CANCEL" = "1" ]; then
  echo "==> [3/3] cancel: POST $BASE/cancel session_id=$SID"
  curl -sS -o /dev/null -w '    status=%{http_code}\n' -X POST "$BASE/cancel" \
    -H "X-OrgPad-Token: $TOKEN" -H 'Content-Type: application/json' --data "{\"session_id\":\"$SID\"}"
  exit 0
fi

echo "==> [3/3] result: POST $BASE/result with fixture png+drawing"
PNG_B64="$(base64 < "$PNG" | tr -d '\n')"
DRAW_B64="$(base64 < "$DRAWING" | tr -d '\n')"
BODY_FILE="$(mktemp)"; trap 'rm -f "$BODY_FILE"' EXIT
printf '{"session_id":"%s","png":"%s","drawing":"%s"}' "$SID" "$PNG_B64" "$DRAW_B64" > "$BODY_FILE"
RESULT_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/result" \
  -H "X-OrgPad-Token: $TOKEN" -H 'Content-Type: application/json' --data-binary "@$BODY_FILE")"
echo "    status=$RESULT_STATUS"
[ "$RESULT_STATUS" = "200" ] || exit 4
echo "==> done."
