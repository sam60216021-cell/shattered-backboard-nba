"""Targeted NBA retrieval and resumable, content-addressed iOS snapshots.

Feed files remain authoritative server archives. App calculations are separate
observations, not replacements for feeds or prediction algorithms. Temporary
snapshot storage is disposable on Render Free; the client reconciles every send.
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import os
from pathlib import Path
import re
import sqlite3
import statistics
import tempfile
import time
from functools import lru_cache
from contextlib import contextmanager
from typing import Literal, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

DATA = Path(__file__).resolve().parent / "data"
SNAPSHOT_DB = str(Path(tempfile.gettempdir()) / "nba-ai-snapshots-v1.sqlite")
router = APIRouter(prefix="/nba/ai")
FEEDS = {"roster": "players", "stats": "players", "standings": "standings",
         "schedule": "games", "lineups": "rows", "team_advanced": "teams",
         "team_position_splits": "splits", "player_advanced": "players", "player_logs": "logs_by_player"}


def authenticate(token):
    from chat_api import authorize
    authorize(token, require_openai=False)


@lru_cache(maxsize=12)
def _read(path, revision):
    return json.loads(Path(path).read_text())


def feed(name):
    if name not in FEEDS:
        raise ValueError("Unknown feed")
    path = DATA / (name + ".json")
    try:
        stat = path.stat()
        return _read(str(path), (stat.st_mtime_ns, stat.st_size))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise HTTPException(503, "NBA feed could not be read")


@contextmanager
def database():
    db = None
    try:
        db = sqlite3.connect(SNAPSHOT_DB, timeout=10)
        db.execute("CREATE TABLE IF NOT EXISTS blobs (digest TEXT PRIMARY KEY, body TEXT NOT NULL, touched REAL NOT NULL)")
        with db:
            yield db
    except sqlite3.Error:
        raise HTTPException(503, {"code": "app_data_sync_unavailable", "message": "Temporary app data storage unavailable; no automatic retry"}) from None
    finally:
        if db is not None:
            db.close()


def validate_manifest(records):
    if len(records) > 4096 or any(not isinstance(k, str) or len(k) > 160 or
            not isinstance(v, str) or not re.fullmatch(r"[a-f0-9]{64}", v) for k, v in records.items()):
        raise HTTPException(422, "Invalid app data manifest")


class SyncCheck(BaseModel):
    records: dict[str, str]


class SyncRecord(BaseModel):
    digest: str = Field(pattern=r"^[a-f0-9]{64}$")
    body: str = Field(max_length=500_000)


@router.post("/sync/check")
def sync_check(value: SyncCheck, x_chat_token: Optional[str] = Header(default=None)):
    authenticate(x_chat_token)
    validate_manifest(value.records)
    now = time.time()
    with database() as db:
        db.execute("DELETE FROM blobs WHERE touched < ?", (now - 86400,))
        available = {row[0] for row in db.execute("SELECT digest FROM blobs")}
        db.executemany("UPDATE blobs SET touched=? WHERE digest=?", [(now, d) for d in set(value.records.values()) & available])
    return {"missing": sorted(set(value.records.values()) - available), "storage": "ephemeral", "protocol": 1}


@router.post("/sync/record")
def sync_record(value: SyncRecord, x_chat_token: Optional[str] = Header(default=None)):
    authenticate(x_chat_token)
    if hashlib.sha256(value.body.encode()).hexdigest() != value.digest:
        raise HTTPException(422, "App data digest mismatch")
    try:
        obj = json.loads(value.body, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(obj, dict):
            raise ValueError()
        json.dumps(obj, allow_nan=False)
    except (ValueError, RecursionError):
        raise HTTPException(422, "Invalid app data record")
    with database() as db:
        db.execute("DELETE FROM blobs WHERE touched < ?", (time.time() - 86400,))
        size = db.execute("SELECT COALESCE(SUM(length(body)),0) FROM blobs").fetchone()[0]
        if size + len(value.body.encode()) > 64_000_000 and not db.execute("SELECT 1 FROM blobs WHERE digest=?", (value.digest,)).fetchone():
            raise HTTPException(503, "Temporary app data cache is full; no analysis started")
        db.execute("INSERT OR REPLACE INTO blobs VALUES (?,?,?)", (value.digest, value.body, time.time()))
    return {"digest": value.digest, "stored": True}


class SyncBatch(BaseModel):
    records: list[SyncRecord] = Field(max_length=20)


@router.post("/sync/records")
def sync_records(value: SyncBatch, x_chat_token: Optional[str] = Header(default=None)):
    authenticate(x_chat_token)
    # Individual records are content-addressed and idempotent. A partial upload
    # is harmless: the next manifest check requests only what is still missing.
    return {"stored": [sync_record(record, x_chat_token)["digest"] for record in value.records]}


class DataQuery(BaseModel):
    kind: Literal["coverage", "players", "player", "history", "matchup", "team", "projections"]
    player_id: Optional[str] = Field(default=None, max_length=80)
    search: Optional[str] = Field(default=None, max_length=120)
    team: Optional[str] = Field(default=None, max_length=12)
    opponent: Optional[str] = Field(default=None, max_length=12)
    game_id: Optional[str] = Field(default=None, max_length=80)
    start_date: Optional[str] = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    end_date: Optional[str] = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    season: Optional[int] = Field(default=None, ge=1947, le=2200)
    offset: int = Field(default=0, ge=0, le=1_000_000)
    limit: int = Field(default=20, ge=1, le=50)


class QueryRequest(BaseModel):
    query: DataQuery
    records: dict[str, str] = Field(default_factory=dict)


class DataAccess:
    def __init__(self, records=None):
        self.records = records or {}
        validate_manifest(self.records)
        self.cache = {}
        self.missing = []

    def require_snapshot(self):
        if not self.records:
            return
        with database() as db:
            available = {r[0] for r in db.execute("SELECT digest FROM blobs")}
        missing = set(self.records.values()) - available
        if missing:
            raise HTTPException(409, {"code": "app_data_sync_required", "missing_records": len(missing),
                                      "message": "App data expired or server restarted. Sync again before analysis; no paid request started."})

    def app(self, key):
        digest = self.records.get(key)
        if not digest:
            return {}
        if digest not in self.cache:
            with database() as db:
                row = db.execute("SELECT body FROM blobs WHERE digest=?", (digest,)).fetchone()
            if row:
                self.cache[digest] = json.loads(row[0])
            else:
                self.cache[digest] = {}
                self.missing.append(key)
        return self.cache[digest]

    def coverage(self):
        feeds = {}
        for name, key in FEEDS.items():
            value = feed(name)
            feeds[name] = {"records": len(value.get(key) or []), "available": bool(value.get(key)),
                           "updated_at": value.get("last_updated", value.get("as_of")),
                           "source": value.get("source", value.get("method"))}
        return {"feeds": feeds, "app_records": len(self.records),
                "unavailable": {"play_by_play": "Not collected by the existing app or feed publisher",
                                "rotation_stints": "No substitution/stint feed; minutes and projected lineups only",
                                "tracking_matchups": "Defender assignments are app estimates, not measured tracking data"},
                "projections": "App-only outputs require current phone sync; never inferred from raw statistics",
                "history": "Paginate history; date/season/opponent filters apply before pagination. Missing stats remain null."}

    def players(self):
        result = {}
        for name in ("stats", "roster"):
            for row in feed(name).get("players", []):
                result[str(row["player_id"])] = {k: row.get(k) for k in ("player_id", "name", "team", "pos")}
        for key in self.records:
            if key.startswith("player:"):
                row = self.app(key).get("identity", {})
                if row.get("player_id"):
                    result[row["player_id"]] = row
        # Historical-only players remain discoverable by ID even without a roster name.
        for pid in feed("player_logs").get("logs_by_player", {}):
            result.setdefault(pid, {"player_id": pid, "name": None})
        return sorted(result.values(), key=lambda p: (p.get("name") or "", p["player_id"]))

    def query(self, q):
        query = q if isinstance(q, DataQuery) else DataQuery(**q)
        result = self._query(query)
        logging.getLogger("nba.data").info("stage=query kind=%s rows=%d total=%s missing_app_records=%d",
                                          query.kind, len(result.get("rows", [])), result.get("total"), len(self.missing))
        result["provenance"] = {"server": "Published Render feeds; source timestamps in coverage",
                                "app": "Content-addressed iOS snapshot, observations and model estimates kept separate"}
        return result

    def _query(self, q):
        if not isinstance(q, DataQuery):
            q = DataQuery(**q)
        if q.kind == "coverage":
            return self.coverage()
        if q.kind == "players":
            rows = self.players()
            if q.search:
                rows = [r for r in rows if q.search.casefold() in ((r.get("name") or "") + " " + r["player_id"]).casefold()]
            if q.team:
                rows = [r for r in rows if (r.get("team") or "").upper() == q.team.upper()]
            return page(rows, q)
        if q.kind == "player":
            if not q.player_id:
                return {"error": "player_id required"}
            return {"server": {name: [r for r in feed(name).get("players", []) if str(r.get("player_id")) == q.player_id]
                               for name in ("roster", "stats", "player_advanced")},
                    "app_identity": self.app("player:" + q.player_id).get("identity"),
                    "app_advanced": self.app("player:" + q.player_id).get("advanced"),
                    "aliases": self.app("player:" + q.player_id).get("identity_aliases", []),
                    "note": "Use history for raw observations and projections separately for model comparison."}
        if q.kind == "history":
            if not q.player_id:
                return {"error": "player_id required; use players search first"}
            current = self.app("player:" + q.player_id)
            ids = list(dict.fromkeys([q.player_id] + current.get("identity_aliases", [])))
            server = [r for pid in ids for r in feed("player_logs").get("logs_by_player", {}).get(pid, [])]
            phone = [r for pid in ids for r in self.app("player:" + pid).get("logs", [])]
            # The app stores one row per date. Keep richer server box-score fields
            # and separately expose conflicting local values rather than silently overwrite.
            merged = {}
            for origin, rows in (("render_archive", server), ("ios_snapshot", phone)):
                for row in rows:
                    key = (row.get("game_date"), row.get("opponent"))
                    if key not in merged:
                        merged[key] = {**row, "data_source": origin}
                    else:
                        original = merged[key]
                        conflicts = {k: v for k, v in row.items() if v is not None and original.get(k) is not None and original[k] != v and k not in {"player_id", "season"}}
                        if conflicts:
                            original["app_differences"] = conflicts
                        for k, v in row.items():
                            if original.get(k) is None:
                                original[k] = v
            rows = sorted(merged.values(), key=lambda r: str(r.get("game_date", "")), reverse=True)
            rows = [r for r in rows if (not q.start_date or r.get("game_date", "") >= q.start_date)
                    and (not q.end_date or r.get("game_date", "") <= q.end_date)
                    and (q.season is None or r.get("season") == q.season)
                    and (not q.opponent or (r.get("opponent") or "").upper() == q.opponent.upper())]
            summary = {}
            for stat in ("pts", "reb", "ast", "three_p", "ftm", "fga", "fta", "stl", "blk", "tov", "mp_seconds"):
                values = [r[stat] for r in rows if isinstance(r.get(stat), (float, int)) and not isinstance(r[stat], bool) and math.isfinite(r[stat])]
                summary[stat] = {"n": len(values), "mean": statistics.mean(values) if values else None,
                                 "sd": statistics.pstdev(values) if values else None}
            return {**page(rows, q), "summary_all_matching_games": summary, "player_id": q.player_id,
                    "resolved_player_ids": ids,
                    "server_updated_at": feed("player_logs").get("last_updated"), "missing_app_records": self.missing,
                    "note": "Independent descriptive statistics; not app projections. mp_seconds is seconds."}
        if q.kind == "projections":
            if not q.player_id:
                return {"error": "player_id required"}
            record = self.app("player:" + q.player_id)
            rows = record.get("projections", [])
            if q.game_id:
                rows = [r for r in rows if r.get("game_id") == q.game_id]
            return {**page(rows, q), "model_outputs": "ios_snapshot; estimates, not confirmed outcomes or sportsbook lines",
                    "pipeline_outputs": page([r for r in record.get("pipeline_outputs", []) if not q.game_id or r.get("game_id") == q.game_id], q),
                    "pipeline_run_at": self.app("model_health").get("pipeline_run_at", record.get("pipeline_run_at")),
                    "model_health": self.app("model_health"),
                    "tracked": page([r for r in record.get("tracked", []) if not q.game_id or r.get("gameID") == q.game_id], q), "missing_app_records": self.missing}
        if q.kind == "team":
            if not q.team:
                return {"error": "team required"}
            team = q.team.upper()
            result = {}
            for name in ("standings", "team_advanced", "team_position_splits"):
                value = feed(name)
                result[name] = [r for r in value.get(FEEDS[name], []) if (r.get("abbr") or r.get("team_abbr") or r.get("team") or "").upper() == team]
            return {"team": team, "server": result, "app": self.app("team:" + team),
                    "missing_app_records": self.missing}
        # Date/team/game filters work even when the player is outside today's slate.
        rows = list(feed("schedule").get("games", []))
        if q.game_id:
            rows = [r for r in rows if str(r.get("game_id")) == q.game_id]
        if q.team:
            rows = [r for r in rows if q.team.upper() in (r.get("home"), r.get("away"))]
        if q.opponent:
            rows = [r for r in rows if q.opponent.upper() in (r.get("home"), r.get("away"))]
        if q.start_date:
            rows = [r for r in rows if r.get("date", "") >= q.start_date]
        if q.end_date:
            rows = [r for r in rows if r.get("date", "") <= q.end_date]
        known = {str(r.get("game_id")) for r in rows}
        for key in self.records:
            if key.startswith("game:") and key[5:] not in known:
                r = self.app(key).get("schedule", {})
                if (not q.game_id or key[5:] == q.game_id) and (not q.team or q.team.upper() in (r.get("home"), r.get("away"))) and (not q.opponent or q.opponent.upper() in (r.get("home"), r.get("away"))) and (not q.start_date or r.get("date", "") >= q.start_date) and (not q.end_date or r.get("date", "") <= q.end_date):
                    rows.append(r)
        result = page(rows, q)
        result["rows"] = [{"schedule": r, "app": self.app("game:" + str(r.get("game_id"))),
                           "lineups": [l for l in feed("lineups").get("rows", []) if str(l.get("game_id")) == str(r.get("game_id")) or (l.get("date") == r.get("date") and l.get("home") == r.get("home") and l.get("away") == r.get("away"))]} for r in result["rows"]]
        return {**result, "missing_app_records": self.missing, "note": "App win probabilities and defender assignments are model estimates. Check feed timestamps for injury/lineup freshness."}


def page(rows, q):
    end = q.offset + q.limit
    return {"rows": rows[q.offset:end], "total": len(rows), "offset": q.offset,
            "next_offset": end if end < len(rows) else None}


@router.post("/query")
def query_endpoint(value: QueryRequest, x_chat_token: Optional[str] = Header(default=None)):
    authenticate(x_chat_token)
    return DataAccess(value.records).query(value.query)
