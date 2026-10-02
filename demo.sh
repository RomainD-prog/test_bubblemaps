# Raccourcis pour la démo : à charger avec  source demo.sh
k() { kubectl --context k3d-bubblemaps "$@"; }
ch() { k -n bubblemaps exec -i clickhouse-0 -- sh -c 'clickhouse-client --password "$CLICKHOUSE_PASSWORD" "$@"' _ "$@"; }
fresh() { ch -q "SELECT count() AS lignes, dateDiff('second', max(timestamp), now()) AS fraicheur_s FROM bubblemaps.transfers FORMAT Vertical"; }
export PUBLIC_URL="$(cat .runtime/public-url 2>/dev/null)"
echo "Raccourcis chargés : k, ch, fresh. URL publique : $PUBLIC_URL"
