# Guide de démonstration — entretien technique

Toutes les commandes sont à lancer depuis la racine du dépôt. Ne jamais afficher
`api_key.txt` ni les Secrets Kubernetes pendant le partage d'écran.

> **Repère important :** sauf mention `[VM]`, toutes les commandes de ce guide
> sont lancées sur le Mac (`➜ test_bubblemaps`). Le prompt
> `lima@colima-bubblemaps` signifie que vous êtes dans la VM. `k3d`, `kubectl`,
> `tmux` et `docker context` sont installés sur le Mac, pas dans la VM.

## 1. Préparer la session

Vérifier que la VM, Kubernetes et le tunnel sont actifs :

```bash
unset DOCKER_HOST
docker context use colima-bubblemaps
colima status --profile bubblemaps
k3d cluster list
tmux list-sessions
```

Si le Mac a redémarré :

```bash
colima start --profile bubblemaps
docker context use colima-bubblemaps
unset DOCKER_HOST
k3d cluster start bubblemaps
./scripts/start-tunnel.sh
```

Récupérer l'URL courante et définir un raccourci Kubernetes :

```bash
export PUBLIC_URL="$(cat .runtime/public-url)"
k() { kubectl --context k3d-bubblemaps "$@"; }

echo "$PUBLIC_URL"
curl -fsS "$PUBLIC_URL/health/ready"
```

Phrase d'introduction :

> J'ai choisi une VM Linux Colima locale pour ne pas dépendre d'un crédit
> cloud. k3d exécute une distribution k3s mono-nœud dans cette VM. ClickHouse
> consomme directement Confluent Cloud avec son moteur Kafka, puis une vue
> matérialisée normalise les événements dans une table MergeTree. FastAPI
> interroge cette table en lecture seule et Traefik l'expose via un tunnel
> Cloudflare.

## 2. Montrer la VM et Kubernetes

Entrer dans la VM :

```bash
# [MAC]
colima ssh --profile bubblemaps

# [VM] Le prompt commence maintenant par lima@colima-bubblemaps
uname -a
free -h
df -h
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

# Revenir sur le Mac (Ctrl+C n'a pas cet effet)
exit
```

Vérifier que le prompt du Mac est revenu, puis montrer l'état du cluster :

```bash
# [MAC]
k get nodes -o wide
k -n bubblemaps get pods,services,ingress,pvc
k -n bubblemaps get statefulset,deployment,job
```

Points à expliquer :

- ClickHouse est un `StatefulSet` avec un PVC de 20 Gio.
- FastAPI est un `Deployment` de deux replicas sans état.
- Traefik, inclus avec k3s, route le trafic HTTP vers le service FastAPI.
- Les probes `liveness` et `readiness` empêchent d'envoyer du trafic à un
  conteneur non opérationnel.
- Les ressources CPU/mémoire sont bornées dans les manifests.

Afficher les probes et ressources sans révéler de secret :

```bash
k -n bubblemaps describe deployment api
k -n bubblemaps describe statefulset clickhouse
```

## 3. Démontrer l'ingestion Kafka → ClickHouse

Afficher les tables :

```bash
k -n bubblemaps exec clickhouse-0 -- sh -lc \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" \
  --query "SHOW TABLES FROM bubblemaps"'
```

Afficher le schéma de stockage :

```bash
k -n bubblemaps exec clickhouse-0 -- sh -lc \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" \
  --query "SHOW CREATE TABLE bubblemaps.transfers FORMAT Vertical"'
```

Afficher la santé du consommateur, les partitions et les offsets :

```bash
k -n bubblemaps exec clickhouse-0 -- sh -lc \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" --query "
    SELECT
      table,
      assignments.topic,
      assignments.partition_id,
      assignments.current_offset,
      num_messages_read,
      num_commits,
      length(exceptions.text) AS error_count
    FROM system.kafka_consumers
    FORMAT Vertical
  "'
```

Le résultat attendu montre le topic `transfer_shib`, six partitions, des offsets
qui avancent et `error_count = 0`.

Montrer les données stockées et leur fraîcheur :

```bash
k -n bubblemaps exec clickhouse-0 -- sh -lc \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" --query "
    SELECT
      count() AS transfers,
      min(timestamp) AS first_event,
      max(timestamp) AS last_event,
      dateDiff(second, max(timestamp), now()) AS freshness_seconds
    FROM bubblemaps.transfers
    FORMAT Vertical
  "'
```

Afficher quelques transferts :

```bash
k -n bubblemaps exec clickhouse-0 -- sh -lc \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" --query "
    SELECT
      timestamp,
      transaction_hash,
      from_address,
      to_address,
      toDecimal256(value_raw, 18) / 1000000000000000000 AS value_shib
    FROM bubblemaps.transfers
    ORDER BY timestamp DESC
    LIMIT 5
    FORMAT PrettyCompact
  "'
```

Points à expliquer :

- `Kafka Engine` gère le groupe `bubblemaps-romain_durieux`.
- La connexion Confluent utilise SASL_SSL ; les identifiants viennent d'un
  Secret Kubernetes injecté dans ClickHouse.
- `RawBLOB` expose un message Kafka par ligne à la vue matérialisée.
- Le champ `amount` a été vérifié sur le flux réel : il contient l'unité brute
  ERC-20, souvent en notation scientifique. La conversion SHIB divise donc par
  `10^18`.
- La vue matérialisée lit le texte JSON directement en `Decimal256`, sans
  conversion intermédiaire en `Float64`.
- `ReplacingMergeTree` déduplique sur la clé de tri complète
  `(timestamp, unique_id)`, pas sur `unique_id` seul. Les messages sans timestamp
  valide sont rejetés afin qu'un rejeu conserve une clé déterministe.
- Le partitionnement mensuel et l'ordre `(timestamp, unique_id)` accélèrent les
  lectures temporelles.
- Le TTL supprime les événements de plus d'un an.

## 4. Démontrer l'API publique

Documentation interactive :

```bash
open "$PUBLIC_URL/docs"
```

Derniers transferts :

```bash
curl -fsS "$PUBLIC_URL/transfers?limit=3" | python3 -m json.tool
```

Statistiques sur les dernières 24 heures :

```bash
curl -fsS "$PUBLIC_URL/stats/overview?window_hours=24" | python3 -m json.tool
```

Activité d'une adresse récupérée depuis le flux :

```bash
export ADDRESS="$(
  curl -fsS "$PUBLIC_URL/transfers?limit=1" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["from_address"])'
)"

echo "$ADDRESS"
curl -fsS "$PUBLIC_URL/addresses/$ADDRESS/transfers?limit=5" |
  python3 -m json.tool
```

Points à expliquer :

- FastAPI utilise un compte ClickHouse limité à `SELECT`.
- Les adresses Ethereum sont validées par une expression régulière.
- `limit` est borné entre 1 et 200.
- Les décimaux sont sérialisés sous forme de chaînes pour éviter une nouvelle
  perte de précision dans JSON.
- `/health/live` vérifie le processus et `/health/ready` teste ClickHouse.

## 5. Montrer l'observabilité et la résilience

Logs et événements :

```bash
k -n bubblemaps logs deployment/api --tail=30
k -n bubblemaps logs statefulset/clickhouse --tail=30
k -n bubblemaps get events --sort-by=.metadata.creationTimestamp
```

Afficher les redémarrages et la consommation de ressources :

```bash
k -n bubblemaps get pods \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'
k top pods -n bubblemaps 2>/dev/null || echo "metrics-server non installé sur ce cluster minimal"
```

Démonstration facultative d'auto-réparation de l'API :

```bash
k -n bubblemaps delete pod -l app=api --wait=false
k -n bubblemaps rollout status deployment/api --timeout=2m
k -n bubblemaps get pods
curl -fsS "$PUBLIC_URL/health/ready"
```

Le `Deployment` recrée automatiquement les deux replicas. Ne pas supprimer le
pod ClickHouse pendant la démonstration : il redémarrerait correctement grâce au
PVC, mais l'API serait momentanément indisponible sur ce cluster mono-nœud.

## 6. Montrer le code important

Ouvrir les fichiers dans cet ordre :

1. `k8s/clickhouse.yaml` — stockage persistant, ressources et probes.
2. `k8s/clickhouse-kafka-config.yaml` — connexion Kafka SASL_SSL.
3. `clickhouse/01_schema.sql` — modèle, partitionnement, tri et TTL.
4. `clickhouse/02_kafka.sql.template` — Kafka Engine et vue matérialisée.
5. `app/main.py` — repository ClickHouse et endpoints FastAPI.
6. `k8s/api.yaml` — replicas, sécurité du conteneur et ingress.
7. `scripts/deploy-colima.sh` — déploiement idempotent.

Lancer les contrôles qualité :

```bash
PYTHONPATH=.deps python3 -m pytest -q
PYTHONPATH=.deps python3 -m ruff check app tests
bash -n scripts/*.sh
```

## 7. Questions d'architecture probables

### Pourquoi ClickHouse ?

Le flux est append-only et les endpoints font surtout des lectures temporelles
et des agrégations. ClickHouse compresse bien les colonnes, scanne rapidement de
grands volumes et intègre nativement Kafka.

### Pourquoi k3s/k3d ?

Le sujet impose Kubernetes, mais un cluster complet serait surdimensionné pour
une seule VM. k3s conserve les API Kubernetes utiles avec une empreinte faible ;
k3d rend le déploiement local reproductible.

### Quelle garantie de livraison ?

Le moteur Kafka et la vue matérialisée fournissent une sémantique au moins une
fois. Un message peut donc être rejoué. `ReplacingMergeTree` converge vers une
ligne par clé `(timestamp, unique_id)`, mais la déduplication n'est pas
instantanée.

### Comment passer à l'échelle ?

1. Augmenter les consommateurs jusqu'au nombre de partitions Kafka.
2. Déployer un vrai cluster Kubernetes multi-nœud.
3. Utiliser ClickHouse Keeper et des tables `ReplicatedMergeTree`.
4. Sharder ClickHouse et placer un `Distributed` table devant les shards.
5. Pré-agréger les statistiques avec `AggregatingMergeTree`.
6. Ajouter Prometheus/Grafana, sauvegardes objet et alertes sur le lag Kafka.
7. Utiliser cert-manager, un domaine stable et External Secrets/Vault.

### Quelles limites faut-il annoncer franchement ?

- La VM et ClickHouse sont mono-nœud : pas de haute disponibilité.
- Le Quick Tunnel n'a pas de garantie de disponibilité et son URL change s'il
  est recréé.
- Le champ Kafka `amount` est écrit comme nombre JSON en notation scientifique
  avec un nombre limité de chiffres significatifs. ClickHouse lit directement
  son texte en `Decimal256`, mais la précision déjà perdue côté producteur est
  irrécupérable. Le contrat devrait fournir un entier ou une chaîne décimale.
- Les statistiques agrègent actuellement la table brute.
- Il manque un Schema Registry et une dead-letter queue pour les messages
  invalides.
- L'API n'a pas d'authentification ni de rate limiting dans cette démonstration.

## 8. Fin de démonstration

Ne lancer ces commandes qu'après l'entretien :

```bash
tmux kill-session -t bubblemaps-cloudflared
k3d cluster stop bubblemaps
colima stop --profile bubblemaps
```

Pour tout relancer ensuite :

```bash
colima start --profile bubblemaps
docker context use colima-bubblemaps
unset DOCKER_HOST
k3d cluster start bubblemaps
./scripts/start-tunnel.sh
```
