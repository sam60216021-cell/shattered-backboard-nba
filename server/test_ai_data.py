"""Data integration tests: fixtures and real checked-in feeds, no paid requests."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import asyncio
from types import SimpleNamespace
import ai_data as data
import app
import chat_api as chat
from test_chat_api import request, response


class TestClient:
    """Exercise the actual ASGI routes without a network or test dependency."""
    def __init__(self, application):
        self.application = application

    def post(self, path, headers=None, json=None, content=None):
        import json as codec
        body = content if content is not None else codec.dumps(json).encode()
        async def run():
            events = []
            delivered = False
            async def receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return {"type": "http.disconnect"}
            async def send(event):
                events.append(event)
            scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"},
                     "http_version": "1.1", "method": "POST", "scheme": "http", "path": path,
                     "raw_path": path.encode(), "query_string": b"", "root_path": "",
                     "headers": [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()] + [(b"content-type", b"application/json")],
                     "client": ("127.0.0.1", 1), "server": ("test", 80)}
            await self.application(scope, receive, send)
            status = next(e["status"] for e in events if e["type"] == "http.response.start")
            output = b"".join(e.get("body", b"") for e in events if e["type"] == "http.response.body").decode()
            return SimpleNamespace(status_code=status, text=output, json=lambda: codec.loads(output))
        return asyncio.run(run())


class DataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        for target, value in [("SNAPSHOT_DB", self.temp.name + "/snap.sqlite"), ("DATA", Path(self.temp.name))]:
            p = patch.object(data, target, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.dict(os.environ, {"NBA_CHAT_TOKEN": "fixture-token"})
        p.start()
        self.addCleanup(p.stop)
        self.client = TestClient(app.app)
        self.headers = {"X-Chat-Token": "fixture-token"}
        self.feed("roster", {"players": [{"player_id": "p", "name": "Player Example", "team": "BOS"}]})
        self.feed("player_logs", {"last_updated": "2026-11-15", "logs_by_player": {"p": [
            {"game_date": "2026-11-14", "opponent": "NYK", "season": 2027, "pts": 20, "ast": None},
            {"game_date": "2026-11-12", "opponent": "NYK", "season": 2027, "pts": 30, "ast": 0},
            {"game_date": "2025-11-12", "opponent": "LAL", "season": 2026, "pts": 10}]}})
        self.feed("schedule", {"games": [{"game_id": "g", "date": "2026-11-15", "away": "BOS", "home": "NYK"}]})
        self.feed("lineups", {"rows": [{"game_id": "g", "away_lineup": [{"name": "Player Example", "status": "QUESTIONABLE"}]}]})

    def feed(self, name, value):
        (data.DATA / (name + ".json")).write_text(json.dumps(value))

    def upload(self, record):
        body = json.dumps(record)
        digest = hashlib.sha256(body.encode()).hexdigest()
        r = self.client.post("/nba/ai/sync/records", headers=self.headers,
                             json={"records": [{"digest": digest, "body": body}]})
        self.assertEqual(r.status_code, 200, r.text)
        return digest

    def test_authentication_without_openai_credential(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": ""}):
            self.assertEqual(self.client.post("/nba/ai/query", json={"query": {"kind": "coverage"}}).status_code, 401)
            self.assertEqual(self.client.post("/nba/ai/query", headers=self.headers, json={"query": {"kind": "coverage"}}).status_code, 200)

    def test_historical_query_filters_before_pagination_and_preserves_null(self):
        access = data.DataAccess()
        found = access.query({"kind": "players", "search": "example"})
        self.assertEqual(found["rows"][0]["player_id"], "p")
        result = access.query({"kind": "history", "player_id": "p", "opponent": "NYK", "season": 2027, "limit": 1})
        self.assertEqual(result["total"], 2)
        self.assertEqual(result["next_offset"], 1)
        self.assertIsNone(result["rows"][0]["ast"])
        self.assertEqual(result["summary_all_matching_games"]["pts"]["mean"], 25)
        self.assertEqual(result["summary_all_matching_games"]["ast"]["n"], 1)
        self.assertEqual(access.query({"kind": "history", "player_id": "p", "end_date": "2025-12-01"})["total"], 1)

    def test_incremental_sync_resume_restart_and_digest_validation(self):
        digest = self.upload({"identity": {"player_id": "p"}, "logs": []})
        self.assertEqual(self.upload({"identity": {"player_id": "p"}, "logs": []}), digest)
        with data.database() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM blobs").fetchone()[0], 1)
        manifest = {"player:p": digest}
        for _ in range(2):
            result = self.client.post("/nba/ai/sync/check", headers=self.headers, json={"records": manifest})
            self.assertEqual(result.json()["missing"], [])
        bad = self.client.post("/nba/ai/sync/record", headers=self.headers, json={"digest": digest, "body": "{}"})
        self.assertEqual(bad.status_code, 422)
        Path(data.SNAPSHOT_DB).unlink()
        result = self.client.post("/nba/ai/sync/check", headers=self.headers, json={"records": manifest})
        self.assertEqual(result.json()["missing"], [digest])
        result = data.DataAccess(manifest).query({"kind": "projections", "player_id": "p"})
        self.assertEqual(result["missing_app_records"], ["player:p"])
        self.assertEqual(result["rows"], [])

    def test_snapshot_scope_and_history_conflicts(self):
        digest = self.upload({"identity": {"player_id": "p", "name": "Example"}, "logs": [
            {"game_date": "2026-11-14", "opponent": "NYK", "season": 2027, "pts": 22},
            {"game_date": "2026-11-15", "opponent": "CHI", "season": 2027, "pts": 40}]})
        self.assertEqual(data.DataAccess().query({"kind": "history", "player_id": "p"})["total"], 3)
        result = data.DataAccess({"player:p": digest}).query({"kind": "history", "player_id": "p"})
        self.assertEqual(result["total"], 4)
        self.assertEqual(result["rows"][1]["pts"], 20)
        self.assertEqual(result["rows"][1]["app_differences"]["pts"], 22)

    def test_matchup_projections_are_separate_from_observations(self):
        player = self.upload({"projections": [{"game_id": "g", "stats": {"PTS": {"analytics": 25, "ai": 23}}}],
                              "pipeline_outputs": [{"game_id": "g", "model": "Blended", "value": 24}]})
        game = self.upload({"schedule": {"game_id": "g"}, "simulation": {"home_win_probability": .6}})
        records = {"player:p": player, "game:g": game}
        result = self.client.post("/nba/ai/query", headers=self.headers, json={"records": records, "query": {"kind": "matchup", "team": "BOS", "opponent": "NYK"}})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()["rows"][0]["app"]["simulation"]["home_win_probability"], .6)
        self.assertEqual(result.json()["rows"][0]["lineups"][0]["away_lineup"][0]["status"], "QUESTIONABLE")
        projected = data.DataAccess(records).query({"kind": "projections", "player_id": "p", "game_id": "g"})
        self.assertEqual(projected["pipeline_outputs"]["rows"][0]["value"], 24)
        historical = data.DataAccess(records).query({"kind": "history", "player_id": "p"})
        self.assertNotIn("projections", historical)

    def test_bad_query_and_missing_feed_are_explicit(self):
        response = self.client.post("/nba/ai/query", headers=self.headers, json={"query": {"kind": "history", "limit": 100000}})
        self.assertEqual(response.status_code, 422)
        result = data.DataAccess().coverage()
        self.assertFalse(result["feeds"]["team_advanced"]["available"])
        self.assertIn("play_by_play", result["unavailable"])

    def test_model_tool_continuation_fetches_player_outside_shortlist(self):
        function = {"type": "function_call", "name": "query_nba_data", "call_id": "q", "arguments": json.dumps({"kind": "history", "player_id": "p"})}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([function]),
                {"input_tokens": 1600}, response()]) as provider:
            result = chat.run_analysis(request(context={"players": []}, web=False))
        self.assertEqual(result["stop_reason"], "completed")
        body = provider.call_args.args[1]
        outputs = [r for r in body["input"] if r.get("type") == "function_call_output"]
        self.assertEqual(json.loads(outputs[0]["output"])["total"], 3)
        self.assertEqual(body["max_output_tokens"], 50000)
        self.assertLess(result["estimated_cost"], .25)

    def test_missing_snapshot_rejected_before_paid_request(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "fixture"}), patch.object(chat, "post_openai") as provider:
            result = self.client.post("/nba/chat", headers=self.headers, json={
                "analysis_id": "missing-snapshot-fixture", "context": {"players": [], "data_records": {"player:p": "a" * 64}},
                "messages": [{"role": "user", "content": "Analyze player"}]})
        self.assertEqual(result.status_code, 409)
        self.assertEqual(result.json()["detail"]["code"], "app_data_sync_required")
        provider.assert_not_called()

    def test_batch_tool_queries_and_schema(self):
        schema = next(t for t in chat.TOOLS if t["name"] == "query_nba_data")["parameters"]
        self.assertEqual(schema["required"], ["queries"])
        function = {"type": "function_call", "name": "query_nba_data", "call_id": "batch", "arguments": json.dumps({"queries": [
            {"kind": "history", "player_id": "p"}, {"kind": "matchup", "game_id": "g"}]})}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([function]),
                {"input_tokens": 2000}, response()]) as provider:
            result = chat.run_analysis(request())
        self.assertEqual(result["stop_reason"], "completed")
        outputs = [r for r in provider.call_args.args[1]["input"] if r.get("type") == "function_call_output"]
        self.assertEqual(len(json.loads(outputs[0]["output"])["results"]), 2)

    def test_phone_only_matchup_and_identity_alias_history(self):
        alias = self.upload({"identity": {"player_id": "new", "name": "Player Example"}, "identity_aliases": ["p"]})
        game = self.upload({"schedule": {"game_id": "phone-only", "date": "2026-11-16", "away": "BOS", "home": "LAL"},
                            "simulation": {"home_win_probability": .55}})
        access = data.DataAccess({"player:new": alias, "game:phone-only": game})
        result = access.query({"kind": "history", "player_id": "new"})
        self.assertEqual(result["total"], 3)
        self.assertEqual(result["resolved_player_ids"], ["new", "p"])
        result = access.query({"kind": "matchup", "team": "BOS", "opponent": "LAL"})
        self.assertEqual(result["rows"][0]["app"]["simulation"]["home_win_probability"], .55)

    def test_unwritable_snapshot_storage_is_clear_error(self):
        with patch.object(data, "SNAPSHOT_DB", self.temp.name + "/absent/cache.sqlite"):
            result = self.client.post("/nba/ai/sync/check", headers=self.headers, json={"records": {}})
        self.assertEqual(result.status_code, 503)
        self.assertEqual(result.json()["detail"]["code"], "app_data_sync_unavailable")

    def test_body_limit_applies_to_sync(self):
        response = self.client.post("/nba/ai/sync/record", headers=self.headers, content=b"x" * 700001)
        self.assertEqual(response.status_code, 413)


class RealArchiveTests(unittest.TestCase):
    def test_actual_player_history_and_matchup(self):
        access = data.DataAccess()
        result = access.query({"kind": "players", "search": "LeBron"})
        self.assertTrue(result["rows"])
        pid = result["rows"][0]["player_id"]
        history = access.query({"kind": "history", "player_id": pid, "limit": 2})
        self.assertGreater(history["total"], 10)
        self.assertEqual(len(history["rows"]), 2)
        self.assertIsNotNone(history["summary_all_matching_games"]["pts"]["mean"])
        game = data.feed("schedule")["games"][0]
        matchup = access.query({"kind": "matchup", "team": game["away"], "opponent": game["home"], "game_id": game["game_id"]})
        self.assertEqual(matchup["total"], 1)
        self.assertEqual(matchup["rows"][0]["schedule"]["game_id"], game["game_id"])


if __name__ == "__main__":
    unittest.main()
