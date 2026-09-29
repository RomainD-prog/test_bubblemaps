from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Any

import clickhouse_connect
from clickhouse_connect.driver.client import Client
from fastapi import Depends, FastAPI, HTTPException, Path, Query, Request
from pydantic import BaseModel
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    clickhouse_host: str = "localhost"
    clickhouse_port: int = 8123
    clickhouse_database: str = "bubblemaps"
    clickhouse_user: str = "api"
    clickhouse_password: str = ""
    clickhouse_secure: bool = False


class Transfer(BaseModel):
    unique_id: str
    transaction_hash: str
    timestamp: datetime
    from_address: str
    to_address: str
    value_raw: Decimal
    value_shib: Decimal


class TransferPage(BaseModel):
    items: list[Transfer]
    limit: int


class OverviewStats(BaseModel):
    window_hours: int
    transfer_count: int
    unique_senders: int
    unique_receivers: int
    volume_shib: Decimal
    first_transfer_at: datetime | None
    last_transfer_at: datetime | None


TRANSFER_COLUMNS = """
    unique_id,
    transaction_hash,
    timestamp,
    from_address,
    to_address,
    value_raw,
    value_raw / 1000000000000000000 AS value_shib
"""


def _rows(result: Any) -> list[dict[str, Any]]:
    return [dict(zip(result.column_names, row, strict=True)) for row in result.result_rows]


class TransferRepository:
    def __init__(self, client: Client) -> None:
        self.client = client

    def ping(self) -> bool:
        return self.client.ping()

    def latest(self, limit: int) -> list[dict[str, Any]]:
        return _rows(
            self.client.query(
                f"""
                SELECT {TRANSFER_COLUMNS}
                FROM transfers
                ORDER BY timestamp DESC, unique_id DESC
                LIMIT {{limit:UInt16}}
                """,
                parameters={"limit": limit},
            )
        )

    def by_address(self, address: str, limit: int) -> list[dict[str, Any]]:
        return _rows(
            self.client.query(
                f"""
                SELECT {TRANSFER_COLUMNS}
                FROM transfers
                WHERE (from_address = {{address:String}} OR to_address = {{address:String}})
                ORDER BY timestamp DESC, unique_id DESC
                LIMIT {{limit:UInt16}}
                """,
                parameters={
                    "address": address.lower(),
                    "limit": limit,
                },
            )
        )

    def overview(self, window_hours: int) -> dict[str, Any]:
        result = self.client.query(
            """
            SELECT
                count() AS transfer_count,
                uniqCombined64(from_address) AS unique_senders,
                uniqCombined64(to_address) AS unique_receivers,
                sum(value_raw) / 1000000000000000000 AS volume_shib,
                min(timestamp) AS first_transfer_at,
                max(timestamp) AS last_transfer_at
            FROM transfers
            WHERE timestamp >= now() - toIntervalHour({window_hours:UInt16})
            """,
            parameters={"window_hours": window_hours},
        )
        values = _rows(result)[0]
        values["window_hours"] = window_hours
        return values


def create_client(settings: Settings) -> Client:
    return clickhouse_connect.get_client(
        host=settings.clickhouse_host,
        port=settings.clickhouse_port,
        database=settings.clickhouse_database,
        username=settings.clickhouse_user,
        password=settings.clickhouse_password,
        secure=settings.clickhouse_secure,
    )


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    client = create_client(Settings())
    app.state.repository = TransferRepository(client)
    yield
    client.close()


app = FastAPI(
    title="Bubblemaps SHIBA Transfers API",
    version="1.0.0",
    description="Read API for SHIBA ERC-20 transfers ingested from Kafka into ClickHouse.",
    lifespan=lifespan,
)


def get_repository(request: Request) -> TransferRepository:
    return request.app.state.repository


Repository = Annotated[TransferRepository, Depends(get_repository)]
PageLimit = Annotated[int, Query(ge=1, le=200)]


@app.get("/health/live", tags=["health"])
def liveness() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/ready", tags=["health"])
def readiness(repository: Repository) -> dict[str, str]:
    try:
        if not repository.ping():
            raise RuntimeError("ClickHouse ping failed")
    except Exception as exc:
        raise HTTPException(status_code=503, detail="ClickHouse unavailable") from exc
    return {"status": "ready"}


@app.get("/transfers", response_model=TransferPage, tags=["transfers"])
def latest_transfers(
    repository: Repository,
    limit: PageLimit = 50,
) -> TransferPage:
    items = [Transfer.model_validate(row) for row in repository.latest(limit)]
    return TransferPage(items=items, limit=limit)


@app.get("/addresses/{address}/transfers", response_model=TransferPage, tags=["transfers"])
def address_transfers(
    repository: Repository,
    address: Annotated[
        str, Path(pattern=r"^0x[a-fA-F0-9]{40}$", description="Ethereum address")
    ],
    limit: PageLimit = 50,
) -> TransferPage:
    items = [Transfer.model_validate(row) for row in repository.by_address(address, limit)]
    return TransferPage(items=items, limit=limit)


@app.get("/stats/overview", response_model=OverviewStats, tags=["statistics"])
def overview(
    repository: Repository,
    window_hours: Annotated[int, Query(ge=1, le=24 * 30)] = 24,
) -> OverviewStats:
    return OverviewStats.model_validate(repository.overview(window_hours))
