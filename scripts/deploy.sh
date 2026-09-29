#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_KEY_FILE="${API_KEY_FILE:-$ROOT_DIR/api_key.txt}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-pkc-z1o60.europe-west1.gcp.confluent.cloud:9092}"

if [[ -z "${VM_IP:-}" ]]; then
  echo "VM_IP is required (for example: export VM_IP=\$(terraform -chdir=terraform output -raw public_ip))" >&2
  exit 1
fi

if [[ -z "${KAFKA_TOPIC:-}" ]]; then
  echo "KAFKA_TOPIC is required; run scripts/discover_topics.sh if the topic name is unknown." >&2
  exit 1
fi

if [[ ! -f "$API_KEY_FILE" ]]; then
  echo "Credentials file not found: $API_KEY_FILE" >&2
  exit 1
fi

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
if [[ -z "$KAFKA_API_KEY" || -z "$KAFKA_API_SECRET" ]]; then
  echo "The credentials file must contain 'API key:' and 'API secret:' entries." >&2
  exit 1
fi

GROUP_SUFFIX="${BUBBLEMAPS_NAME:-${USER:-candidate}}"
GROUP_SUFFIX="$(printf '%s' "$GROUP_SUFFIX" | tr '[:upper:] _' '[:lower:]--' | tr -cd 'a-z0-9-')"
KAFKA_CONSUMER_GROUP="bubblemaps-${GROUP_SUFFIX}"
CLICKHOUSE_ADMIN_PASSWORD="${CLICKHOUSE_ADMIN_PASSWORD:-$(openssl rand -hex 24)}"
CLICKHOUSE_API_PASSWORD="${CLICKHOUSE_API_PASSWORD:-$(openssl rand -hex 24)}"
REMOTE="${SSH_USER}@${VM_IP}"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$REMOTE")

echo "Waiting for k3s on ${VM_IP}..."
until "${SSH[@]}" "sudo k3s kubectl get nodes" >/dev/null 2>&1; do
  sleep 5
done

EXISTING_ADMIN_B64="$("${SSH[@]}" \
  "sudo k3s kubectl -n bubblemaps get secret clickhouse-credentials -o jsonpath='{.data.CLICKHOUSE_ADMIN_PASSWORD}'" \
  2>/dev/null || true)"
EXISTING_API_B64="$("${SSH[@]}" \
  "sudo k3s kubectl -n bubblemaps get secret clickhouse-credentials -o jsonpath='{.data.CLICKHOUSE_API_PASSWORD}'" \
  2>/dev/null || true)"
if [[ -n "$EXISTING_ADMIN_B64" && -n "$EXISTING_API_B64" ]]; then
  CLICKHOUSE_ADMIN_PASSWORD="$(printf '%s' "$EXISTING_ADMIN_B64" | openssl base64 -d -A)"
  CLICKHOUSE_API_PASSWORD="$(printf '%s' "$EXISTING_API_B64" | openssl base64 -d -A)"
fi

echo "Copying sources and building the API image on the VM..."
"${SSH[@]}" "rm -rf /opt/bubblemaps && mkdir -p /opt/bubblemaps"
rsync -az --delete \
  --exclude '.git' \
  --exclude '.venv' \
  --exclude 'api_key*.txt' \
  --exclude 'terraform/.terraform*' \
  --exclude 'terraform/*.tfstate*' \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
  "$ROOT_DIR/" "$REMOTE:/opt/bubblemaps/"
"${SSH[@]}" \
  "cd /opt/bubblemaps && docker build -t bubblemaps-api:local . && docker save bubblemaps-api:local | sudo k3s ctr images import -"

ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
{
  printf 'KAFKA_API_KEY_B64=%s\n' "$(printf '%s' "$KAFKA_API_KEY" | base64)"
  printf 'KAFKA_API_SECRET_B64=%s\n' "$(printf '%s' "$KAFKA_API_SECRET" | base64)"
  printf 'KAFKA_BOOTSTRAP_SERVERS_B64=%s\n' "$(printf '%s' "$KAFKA_BOOTSTRAP_SERVERS" | base64)"
  printf 'KAFKA_TOPIC_B64=%s\n' "$(printf '%s' "$KAFKA_TOPIC" | base64)"
  printf 'KAFKA_CONSUMER_GROUP_B64=%s\n' "$(printf '%s' "$KAFKA_CONSUMER_GROUP" | base64)"
  printf 'CLICKHOUSE_ADMIN_PASSWORD_B64=%s\n' "$(printf '%s' "$CLICKHOUSE_ADMIN_PASSWORD" | base64)"
  printf 'CLICKHOUSE_API_PASSWORD_B64=%s\n' "$(printf '%s' "$CLICKHOUSE_API_PASSWORD" | base64)"
} > "$ENV_FILE"
scp -q -i "$SSH_KEY" "$ENV_FILE" "$REMOTE:/tmp/bubblemaps-deploy.env"

echo "Applying Kubernetes resources..."
"${SSH[@]}" 'bash -se' <<'REMOTE_SCRIPT'
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

echo
echo "Deployment complete:"
echo "  API:  http://${VM_IP}"
echo "  Docs: http://${VM_IP}/docs"
echo "  Consumer group: ${KAFKA_CONSUMER_GROUP}"
