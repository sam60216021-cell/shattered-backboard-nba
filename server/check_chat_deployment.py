"""No-generation deployment check. Reads NBA_CHAT_TOKEN from the environment."""
import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def main():
    base = (sys.argv[1] if len(sys.argv) > 1 else "https://shattered-backboard-nba.onrender.com").rstrip("/")
    with urlopen(base + "/openapi.json", timeout=60) as response:
        paths = json.load(response).get("paths", {})
    if "post" not in paths.get("/nba/chat", {}) or "get" not in paths.get("/nba/chat/status", {}):
        print("FAIL: deployed server is missing chat routes. Deploy server/app.py and server/chat_api.py together.")
        return 1
    print("PASS: chat routes are deployed.")
    token = os.environ.get("NBA_CHAT_TOKEN")
    if not token:
        print("Project access not checked: set NBA_CHAT_TOKEN privately, or use the app's connection check.")
        return 2
    request = Request(base + "/nba/chat/status?model=gpt-6-luna", headers={"X-Chat-Token": token})
    try:
        with urlopen(request, timeout=60) as response:
            result = json.load(response)
            print("HTTP", response.status, "model_access=", bool(result.get("model_access")),
                  "research_configured=", bool(result.get("research_configured")),
                  "storage_mode=", result.get("storage_mode"))
            return 0 if result.get("model_access") else 1
    except HTTPError as error:
        code = "unclassified"
        try:
            detail = json.loads(error.read(8192)).get("detail", {})
            candidate = detail.get("code") if isinstance(detail, dict) else None
            if candidate in {"missing_openai_key", "invalid_cost_settings", "temporary_accounting_unavailable"}:
                code = candidate
        except (ValueError, AttributeError):
            pass
        print("FAIL: readiness HTTP", error.code, "code=", code,
              "— inspect sanitized nba.chat logs. No generation requested.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
