CREATE DATABASE IF NOT EXISTS bubblemaps;

CREATE TABLE IF NOT EXISTS bubblemaps.transfers
(
    unique_id String,
    transaction_hash String,
    timestamp DateTime64(3, 'UTC'),
    from_address String,
    to_address String,
    value_raw Decimal256(0),
    raw_payload String,
    ingested_at DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(ingested_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, unique_id)
TTL toDateTime(timestamp) + INTERVAL 1 YEAR DELETE
SETTINGS index_granularity = 8192;

CREATE USER IF NOT EXISTS api IDENTIFIED WITH sha256_password BY {api_password:String};
ALTER USER api IDENTIFIED WITH sha256_password BY {api_password:String};
GRANT SELECT ON bubblemaps.* TO api;
