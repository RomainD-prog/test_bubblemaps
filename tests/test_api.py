from datetime import UTC, datetime
from decimal import Decimal
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.main import Settings, app, create_client, get_repository

TRANSFER = {
    "unique_id": "97A23779CF9FF7CA",
    "transaction_hash": "0x" + "a" * 64,
    "timestamp": datetime(2026, 1, 1, tzinfo=UTC),
    "from_address": "0x" + "1" * 40,
    "to_address": "0x" + "2" * 40,
    "value_raw": Decimal("1000000000000000000"),
    "value_shib": Decimal("1"),
}


class FakeRepository:
    def ping(self) -> bool:
        return True

    def latest(self, limit: int) -> list[dict]:
        return [TRANSFER]

    def by_address(self, address: str, limit: int) -> list[dict]:
        return [TRANSFER]

    def overview(self, window_hours: int) -> dict:
        return {
            "window_hours": window_hours,
            "transfer_count": 1,
            "unique_senders": 1,
            "unique_receivers": 1,
            "volume_shib": Decimal("1"),
            "first_transfer_at": TRANSFER["timestamp"],
            "last_transfer_at": TRANSFER["timestamp"],
        }


app.dependency_overrides[get_repository] = lambda: FakeRepository()
client = TestClient(app)


def test_latest_transfers() -> None:
    response = client.get("/transfers?limit=10")

    assert response.status_code == 200
    assert response.json()["items"][0]["unique_id"] == "97A23779CF9FF7CA"


def test_address_validation() -> None:
    response = client.get("/addresses/not-an-address/transfers")

    assert response.status_code == 422


def test_overview() -> None:
    response = client.get("/stats/overview?window_hours=48")

    assert response.status_code == 200
    assert response.json()["window_hours"] == 48
    assert response.json()["volume_shib"] == "1"


def test_clickhouse_client_does_not_share_a_session_between_threads() -> None:
    with patch("app.main.clickhouse_connect.get_client") as get_client:
        create_client(Settings())

    assert get_client.call_args.kwargs["autogenerate_session_id"] is False
