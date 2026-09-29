#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${COLIMA_PROFILE:-bubblemaps}"
CLUSTER="${K3D_CLUSTER:-bubblemaps}"
CONTEXT="k3d-${CLUSTER}"
API_KEY_FILE="${API_KEY_FILE:-$ROOT_DIR/api_key.txt}"
KAFKA_TOPIC="${KAFKA_TOPIC:-transfer_shib}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-pkc-z1o60.europe-west1.gcp.confluent.cloud:9092}"

for command in colima docker k3d kubectl cloudflared openssl tmux; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

read_credential() {
  local label="$1"
  awk -F': *' -v label="$label" 'tolower($1) == label {
    value=$2; if (value == "") {getline; value=$0}
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit
  }' "$API_KEY_FILE"
}

KAFKA_API_KEY="$(read_credential "api key")"
KAFKA_API_SECRET="$(read_credential "api secret")"
KAFKA_CONSUMER_GROUP="$(
  awk '/^Consumer group:/ {getline; sub(/^[[:space:]]*Prefixed with[[:space:]]*/, ""); print; exit}' \
    "$API_KEY_FILE"
)"
KAFKA_CONSUMER_GROUP="${KAFKA_CONSUMER_GROUP:-bubblemaps-candidate}"

if ! colima status --profile "$PROFILE" >/dev/null 2>&1; then
  echo "Starting Colima Linux VM..."
  colima start --profile "$PROFILE" --cpu 4 --memory 6 --disk 30
fi
docker context use "colima-${PROFILE}" >/dev/null
unset DOCKER_HOST

if ! k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  echo "Creating k3s cluster in the VM..."
  k3d cluster create "$CLUSTER" \
    --servers 1 \
    --agents 0 \
    --port "8080:80@loadbalancer" \
    --wait
fi

echo "Building and importing the FastAPI image..."
docker build -t bubblemaps-api:local "$ROOT_DIR"
k3d image import bubblemaps-api:local --cluster "$CLUSTER"

kubectl --context "$CONTEXT" apply -f "$ROOT_DIR/k8s/namespace.yaml"
EXISTING_ADMIN_B64="$(
  kubectl --context "$CONTEXT" -n bubblemaps get secret clickhouse-credentials \
    -o "jsonpath={.data.CLICKHOUSE_ADMIN_PASSWORD}" 2>/dev/null || true
)"
EXISTING_API_B64="$(
  kubectl --context "$CONTEXT" -n bubblemaps get secret clickhouse-credentials \
    -o "jsonpath={.data.CLICKHOUSE_API_PASSWORD}" 2>/dev/null || true
)"
if [[ -n "$EXISTING_ADMIN_B64" && -n "$EXISTING_API_B64" ]]; then
  CLICKHOUSE_ADMIN_PASSWORD="$(printf '%s' "$EXISTING_ADMIN_B64" | openssl base64 -d -A)"
  CLICKHOUSE_API_PASSWORD="$(printf '%s' "$EXISTING_API_B64" | openssl base64 -d -A)"
else
  CLICKHOUSE_ADMIN_PASSWORD="$(openssl rand -hex 24)"
  CLICKHOUSE_API_PASSWORD="$(openssl rand -hex 24)"
fi

echo "Applying Kubernetes resources..."
kubectl --context "$CONTEXT" -n bubblemaps create configmap clickhouse-sql \
  --from-file="$ROOT_DIR/clickhouse/01_schema.sql" \
  --from-file="$ROOT_DIR/clickhouse/02_kafka.sql.template" \
  --dry-run=client -o yaml |
  kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" -n bubblemaps create secret generic clickhouse-credentials \
  --from-literal=CLICKHOUSE_ADMIN_PASSWORD="$CLICKHOUSE_ADMIN_PASSWORD" \
  --from-literal=CLICKHOUSE_API_PASSWORD="$CLICKHOUSE_API_PASSWORD" \
  --from-literal=admin-password="$CLICKHOUSE_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" -n bubblemaps create secret generic kafka-credentials \
  --from-literal=KAFKA_API_KEY="$KAFKA_API_KEY" \
  --from-literal=KAFKA_API_SECRET="$KAFKA_API_SECRET" \
  --from-literal=KAFKA_BOOTSTRAP_SERVERS="$KAFKA_BOOTSTRAP_SERVERS" \
  --from-literal=KAFKA_TOPIC="$KAFKA_TOPIC" \
  --from-literal=KAFKA_CONSUMER_GROUP="$KAFKA_CONSUMER_GROUP" \
  --dry-run=client -o yaml |
  kubectl --context "$CONTEXT" apply -f -
kubectl --context "$CONTEXT" -n bubblemaps delete job clickhouse-bootstrap --ignore-not-found
kubectl --context "$CONTEXT" apply -k "$ROOT_DIR/k8s"

kubectl --context "$CONTEXT" -n bubblemaps rollout status statefulset/clickhouse --timeout=5m
kubectl --context "$CONTEXT" -n bubblemaps wait \
  --for=condition=complete job/clickhouse-bootstrap --timeout=5m
kubectl --context "$CONTEXT" -n bubblemaps rollout restart deployment/api
kubectl --context "$CONTEXT" -n bubblemaps rollout status deployment/api --timeout=5m

PUBLIC_URL="$("$ROOT_DIR/scripts/start-tunnel.sh")"
echo
echo "Deployment complete:"
echo "  API:  ${PUBLIC_URL}"
echo "  Docs: ${PUBLIC_URL}/docs"
echo "  VM:   colima ssh --profile ${PROFILE}"
echo "  Topic: ${KAFKA_TOPIC}"
echo "  Consumer group: ${KAFKA_CONSUMER_GROUP}"
