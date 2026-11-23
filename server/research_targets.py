"""Read-only target hit rates. Does not alter or estimate model projections."""
import math

STAT_FIELDS = {"PTS": ("pts",), "REB": ("reb",), "AST": ("ast",),
               "3PM": ("three_p",), "PRA": ("pts", "reb", "ast"),
               "PR": ("pts", "reb"), "PA": ("pts", "ast"), "RA": ("reb", "ast"),
               "FTM": ("ftm",), "STL": ("stl",), "BLK": ("blk",)}


def evaluate_target(data_access, player_id, stat, target, direction):
    if (stat not in STAT_FIELDS or direction not in ("OVER", "UNDER")
            or isinstance(target, bool) or not isinstance(target, (int, float))
            or not math.isfinite(target) or target < 0):
        return {"error": "Provide a supported statistic, finite nonnegative target and OVER/UNDER."}
    history = data_access.query({"kind": "history", "player_id": player_id, "limit": 10})
    if "error" in history:
        return history
    rows = history.get("rows", [])
    windows = {}
    for size in (10, 5):
        observations = []
        for row in rows[:size]:
            fields = STAT_FIELDS[stat]
            values = [row.get(field) for field in fields]
            # Conflicting source values are unknown, never silently selected.
            if (any(field in row.get("app_differences", {}) for field in fields)
                    or not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                               and math.isfinite(v) for v in values)):
                continue
            observations.append(sum(values))
        hits = sum(v > target if direction == "OVER" else v < target for v in observations)
        windows[f"last_{size}"] = {
            "hits": hits, "observations": len(observations),
            "games_available": len(rows[:size]), "missing_observations": len(rows[:size]) - len(observations),
            "pushes": sum(v == target for v in observations),
            "hit_rate": hits / len(observations) if observations else None,
            "complete_window": len(observations) == size,
        }
    return {"player_id": player_id, "stat": stat, "target": target, "direction": direction,
            **windows, "source": "Existing history query; latest games, no opponent filter",
            "note": "Strict OVER/UNDER; equality is a push included in the denominator. Missing/conflicting values stay unknown. Retrieve the app projection separately. Target is an analysis threshold, not a sportsbook line."}
