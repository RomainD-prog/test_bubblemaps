#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="${VM_NAME:-bubblemaps}"
API_KEY_FILE="${API_KEY_FILE:-$ROOT_DIR/api_key.txt}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-pkc-z1o60.europe-west1.gcp.confluent.cloud:9092}"

for command in multipass cloudflared kcat openssl; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

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
FILE_CONSUMER_GROUP="$(
  awk '/^Consumer group:/ {getline; sub(/^[[:space:]]*Prefixed with[[:space:]]*/, ""); print; exit}' \
    "$API_KEY_FILE"
)"
KAFKA_CONSUMER_GROUP="${KAFKA_CONSUMER_GROUP:-${FILE_CONSUMER_GROUP:-bubblemaps-candidate}}"

if [[ -z "${KAFKA_TOPIC:-}" ]]; then
  TOPICS_OUTPUT="$("$ROOT_DIR/scripts/discover_topics.sh")"
  TOPIC_COUNT="$(printf '%s\n' "$TOPICS_OUTPUT" | awk 'NF {count++} END {print count+0}')"
  if [[ "$TOPIC_COUNT" -ne 1 ]]; then
    printf 'Set KAFKA_TOPIC explicitly. Accessible topics:\n' >&2
    printf '%s\n' "$TOPICS_OUTPUT" | awk 'NF {print "  " $0}' >&2
    exit 1
  fi
  KAFKA_TOPIC="$(printf '%s\n' "$TOPICS_OUTPUT" | awk 'NF {print; exit}')"
fi

if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
  echo "Creating Ubuntu VM ${VM_NAME}..."
  multipass launch 24.04 \
    --name "$VM_NAME" \
    --cpus 4 \
    --memory 6G \
    --disk 30G \
    --cloud-init "$ROOT_DIR/vm/cloud-init.yaml"
fi

multipass start "$VM_NAME" >/dev/null 2>&1 || true
echo "Waiting for cloud-init and k3s..."
multipass exec "$VM_NAME" -- cloud-init status --wait
until multipass exec "$VM_NAME" -- sudo k3s kubectl get nodes >/dev/null 2>&1; do
  sleep 5
done

EXISTING_ADMIN_B64="$(
  multipass exec "$VM_NAME" -- sudo k3s kubectl -n bubblemaps get secret \
    clickhouse-credentials -o "jsonpath={.data.CLICKHOUSE_ADMIN_PASSWORD}" 2>/dev/null || true
)"
EXISTING_API_B64="$(
  multipass exec "$VM_NAME" -- sudo k3s kubectl -n bubblemaps get secret \
    clickhouse-credentials -o "jsonpath={.data.CLICKHOUSE_API_PASSWORD}" 2>/dev/null || true
)"
if [[ -n "$EXISTING_ADMIN_B64" && -n "$EXISTING_API_B64" ]]; then
  CLICKHOUSE_ADMIN_PASSWORD="$(printf '%s' "$EXISTING_ADMIN_B64" | openssl base64 -d -A)"
  CLICKHOUSE_API_PASSWORD="$(printf '%s' "$EXISTING_API_B64" | openssl base64 -d -A)"
else
  CLICKHOUSE_ADMIN_PASSWORD="$(openssl rand -hex 24)"
  CLICKHOUSE_API_PASSWORD="$(openssl rand -hex 24)"
fi

echo "Copying the project and building the API image..."
multipass exec "$VM_NAME" -- sudo rm -rf /opt/bubblemaps
multipass exec "$VM_NAME" -- sudo mkdir -p /opt/bubblemaps
tar \
  --exclude='.git' \
  --exclude='.deps' \
  --exclude='.venv' \
  --exclude='.runtime' \
  --exclude='api_key*.txt' \
  --exclude='terraform/.terraform' \
  --exclude='terraform/*.tfstate*' \
  -czf - -C "$ROOT_DIR" . |
  multipass exec "$VM_NAME" -- sudo tar -xzf - -C /opt/bubblemaps
multipass exec "$VM_NAME" -- bash -ec \
  'cd /opt/bubblemaps && sudo docker build -t bubblemaps-api:local . &&
   sudo docker save bubblemaps-api:local | sudo k3s ctr images import -'

ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
encode() { printf '%s' "$1" | openssl base64 -A; }
{
  printf 'KAFKA_API_KEY_B64=%s\n' "$(encode "$KAFKA_API_KEY")"
  printf 'KAFKA_API_SECRET_B64=%s\n' "$(encode "$KAFKA_API_SECRET")"
  printf 'KAFKA_BOOTSTRAP_SERVERS_B64=%s\n' "$(encode "$KAFKA_BOOTSTRAP_SERVERS")"
  printf 'KAFKA_TOPIC_B64=%s\n' "$(encode "$KAFKA_TOPIC")"
  printf 'KAFKA_CONSUMER_GROUP_B64=%s\n' "$(encode "$KAFKA_CONSUMER_GROUP")"
  printf 'CLICKHOUSE_ADMIN_PASSWORD_B64=%s\n' "$(encode "$CLICKHOUSE_ADMIN_PASSWORD")"
  printf 'CLICKHOUSE_API_PASSWORD_B64=%s\n' "$(encode "$CLICKHOUSE_API_PASSWORD")"
} > "$ENV_FILE"
multipass transfer "$ENV_FILE" "$VM_NAME:/tmp/bubblemaps-deploy.env"

echo "Deploying Kubernetes resources..."
multipass exec "$VM_NAME" -- bash -se <<'REMOTE_SCRIPT'
set -euo pipefail
source /tmp/bubblemaps-deploy.env
decode() { printf '%s' "$1" | base64 -d; }
kubectl="sudo k3s kubectl"

$kubectl apply -f /opt/bubblemaps/k8s/namespace.yaml
$kubectl -n bubblemaps create configmap clickhouse-sql \
  --from-file=/opt/bubblemaps/clickhouse/01_schema.sql \
  --from-file=/opt/bubblemaps/clickhouse/02_kafka.sql.template \
  --dry-run=client -o yaml | $kubectl apply -f -
$kubectl -n bubblemaps create secret generic clickhouse-credentials \
  --from-literal=CLICKHOUSE_ADMIN_PASSWORD="$(decode "$CLICKHOUSE_ADMIN_PASSWORD_B64")" \
  --from-literal=CLICKHOUSE_API_PASSWORD="$(decode "$CLICKHOUSE_API_PASSWORD_B64")" \
  --from-literal=admin-password="$(decode "$CLICKHOUSE_ADMIN_PASSWORD_B64")" \
  --dry-run=client -o yaml | $kubectl apply -f -
$kubectl -n bubblemaps create secret generic kafka-credentials \
  --from-literal=KAFKA_API_KEY="$(decode "$KAFKA_API_KEY_B64")" \
  --from-literal=KAFKA_API_SECRET="$(decode "$KAFKA_API_SECRET_B64")" \
  --from-literal=KAFKA_BOOTSTRAP_SERVERS="$(decode "$KAFKA_BOOTSTRAP_SERVERS_B64")" \
  --from-literal=KAFKA_TOPIC="$(decode "$KAFKA_TOPIC_B64")" \
  --from-literal=KAFKA_CONSUMER_GROUP="$(decode "$KAFKA_CONSUMER_GROUP_B64")" \
  --dry-run=client -o yaml | $kubectl apply -f -
$kubectl -n bubblemaps delete job clickhouse-bootstrap --ignore-not-found
$kubectl apply -k /opt/bubblemaps/k8s
rm -f /tmp/bubblemaps-deploy.env

$kubectl -n bubblemaps rollout status statefulset/clickhouse --timeout=5m
$kubectl -n bubblemaps wait --for=condition=complete job/clickhouse-bootstrap --timeout=5m
$kubectl -n bubblemaps rollout restart deployment/api
$kubectl -n bubblemaps rollout status deployment/api --timeout=5m
REMOTE_SCRIPT

VM_IP="$(
  multipass info "$VM_NAME" --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["info"][sys.argv[1]]["ipv4"][0])' \
      "$VM_NAME"
)"
RUNTIME_DIR="$ROOT_DIR/.runtime"
mkdir -p "$RUNTIME_DIR"
if [[ -f "$RUNTIME_DIR/cloudflared.pid" ]]; then
  kill "$(cat "$RUNTIME_DIR/cloudflared.pid")" 2>/dev/null || true
fi
cloudflared tunnel --url "http://${VM_IP}:80" --no-autoupdate \
  > "$RUNTIME_DIR/cloudflared.log" 2>&1 &
echo "$!" > "$RUNTIME_DIR/cloudflared.pid"

PUBLIC_URL=""
for _ in {1..30}; do
  PUBLIC_URL="$(
    awk 'match($0, /https:\/\/[a-z0-9-]+\.trycloudflare\.com/) {
      print substr($0, RSTART, RLENGTH); exit
    }' "$RUNTIME_DIR/cloudflared.log"
  )"
  [[ -n "$PUBLIC_URL" ]] && break
  sleep 1
done
if [[ -z "$PUBLIC_URL" ]]; then
  echo "The deployment is ready, but Cloudflare did not return a URL." >&2
  cat "$RUNTIME_DIR/cloudflared.log" >&2
  exit 1
fi

printf '%s\n' "$PUBLIC_URL" > "$RUNTIME_DIR/public-url"
echo
echo "Deployment complete:"
echo "  API:  ${PUBLIC_URL}"
echo "  Docs: ${PUBLIC_URL}/docs"
echo "  VM:   multipass shell ${VM_NAME}"
echo "  Topic: ${KAFKA_TOPIC}"
echo "  Consumer group: ${KAFKA_CONSUMER_GROUP}"
