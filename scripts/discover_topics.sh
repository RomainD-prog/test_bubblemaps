#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_KEY_FILE="${API_KEY_FILE:-$ROOT_DIR/api_key.txt}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-pkc-z1o60.europe-west1.gcp.confluent.cloud:9092}"

KAFKA_API_KEY="$(
  awk -F': *' 'tolower($1) == "api key" {
    value=$2; if (value == "") {getline; value=$0}
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit
  }' "$API_KEY_FILE"
)"
KAFKA_API_SECRET="$(
  awk -F': *' 'tolower($1) == "api secret" {
    value=$2; if (value == "") {getline; value=$0}
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit
  }' "$API_KEY_FILE"
)"

if command -v kcat >/dev/null 2>&1; then
  KCAT=(kcat)
elif command -v docker >/dev/null 2>&1; then
  KCAT=(docker run --rm edenhill/kcat:1.7.1)
else
  echo "Install kcat or Docker to discover Kafka topics." >&2
  exit 1
fi

"${KCAT[@]}" \
  -b "$KAFKA_BOOTSTRAP_SERVERS" \
  -X security.protocol=SASL_SSL \
  -X sasl.mechanisms=PLAIN \
  -X "sasl.username=$KAFKA_API_KEY" \
  -X "sasl.password=$KAFKA_API_SECRET" \
  -L 2>&1 |
  awk '/^[[:space:]]*topic "/ {gsub(/"/, "", $2); print $2}'
