"""TypeSafe-compatible wire contract tests (/v1/systemone, /v1/models)."""
import json
import urllib.error
import urllib.request

import pytest

from winzling_spark.server import create_app
from winzling_spark.service import TypedDecisionEngine

from test_server import make_engine  # toy engine fixture factory  # noqa: F401

fastapi = pytest.importorskip("fastapi")
uvicorn = pytest.importorskip("uvicorn")
torch = pytest.importorskip("torch")

import threading  # noqa: E402
import time  # noqa: E402


@pytest.fixture(scope="module")
def base_url():
    app = create_app(make_engine(), max_fields=8, window_ms=1.0,
                     api_key="secret-key", resolved_model="toy-resolved")
    yield from _serve(app)


@pytest.fixture(scope="module")
def custom_alias_url():
    app = create_app(make_engine(), max_fields=8, window_ms=1.0,
                     api_key="secret-key", resolved_model="toy-resolved",
                     model_aliases=["custom-alias"])
    yield from _serve(app)


def _serve(app):
    config = uvicorn.Config(app, host="127.0.0.1", port=0, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    port = server.servers[0].sockets[0].getsockname()[1]
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join(timeout=5)


def call(base_url, path, payload=None, token="secret-key", method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(f"{base_url}{path}", data=data, headers=headers,
                                     method=method or ("POST" if data else "GET"))
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, dict(response.headers), json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), json.loads(exc.read())


def valid_request():
    return {
        "state": "payment failing for days",
        "model": "jev-latest",
        "questions": {
            "department": {"type": "choice", "instructions": "Which team",
                           "criteria": {"billing": "Payment", "technical": "Bugs", "sales": "Pricing"}},
            "frustration": {"type": "score", "instructions": "How frustrated",
                            "criteria": ["calm", "annoyed", "furious"]},
            "is_urgent": {"type": "noul", "instructions": "time-sensitive"},
        },
    }


def test_systemone_happy_path(base_url):
    status, headers, body = call(base_url, "/v1/systemone", valid_request())
    assert status == 200
    assert body["model"] == "toy-resolved"
    assert set(body) == {"model", "answers", "usage"}
    department = body["answers"]["department"]
    assert department["type"] == "choice" and department["choice"] in {"billing", "technical", "sales"}
    assert abs(sum(department["probabilities"].values()) - 1.0) < 1e-9
    frustration = body["answers"]["frustration"]
    assert frustration["type"] == "score" and 0.0 <= frustration["score"] <= 2.0
    assert frustration["legend"] == {"0": "calm", "1": "annoyed", "2": "furious"}
    assert set(body["answers"]["is_urgent"]) == {"type", "noul"}
    assert body["usage"]["input_tokens"] > 0 and body["usage"]["output_tokens"] == 0
    assert headers["x-typesafe-request-id"].startswith("req_winzling_")
    assert len(headers["x-typesafe-request-id"]) == len("req_winzling_") + 16


def test_auth_matrix(base_url):
    status, _, body = call(base_url, "/v1/systemone", valid_request(), token=None)
    assert status == 401 and body == {"detail": "Unauthorized"}
    status, _, _ = call(base_url, "/v1/systemone", valid_request(), token="wrong")
    assert status == 401
    status, _, _ = call(base_url, "/v1/models", token=None)
    assert status == 401


def test_models_list(base_url):
    status, _, body = call(base_url, "/v1/models")
    assert status == 200
    names = {model["name"] for model in body["models"]}
    assert {"jev-latest", "jev-preview", "winzling-jev-a8m"} <= names
    assert all(set(model) == {"name", "description", "release_date"} for model in body["models"])


def test_validation_issues_match_reference(base_url):
    # missing required fields -> FastAPI-style missing issues
    status, _, body = call(base_url, "/v1/systemone", {"state": "x"})
    assert status == 422
    kinds = {(issue["type"], tuple(issue["loc"][1:])) for issue in body["detail"]}
    assert ("missing", ("model",)) in kinds and ("missing", ("questions",)) in kinds
    # bad question type -> discriminated error path
    payload = valid_request()
    payload["questions"]["bad"] = {"type": "poem"}
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 422
    assert body["detail"][0]["loc"] == ["body", "questions", "bad", "type"]
    assert body["detail"][0]["msg"] == "Input tag must be 'noul', 'choice', or 'score'"
    # empty choice criteria / empty score criteria
    payload = valid_request()
    payload["questions"]["department"]["criteria"] = {}
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 422 and "at least one label" in body["detail"][0]["msg"]
    payload = valid_request()
    payload["questions"]["frustration"]["criteria"] = []
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 422 and "at least 1 item" in body["detail"][0]["msg"]
    # noul criteria only true/false
    payload = valid_request()
    payload["questions"]["is_urgent"]["criteria"] = {"maybe": "x"}
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 422 and "only 'true' and 'false'" in body["detail"][0]["msg"]


def test_nullable_instructions_and_entry_descriptions(base_url):
    payload = valid_request()
    payload["questions"]["department"]["instructions"] = None
    payload["questions"]["department"]["criteria"]["billing"] = {"kind": "money", "weight": 2}
    payload["questions"]["frustration"]["instructions"] = None
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 200 and "department" in body["answers"]
    # legend preserves the raw criteria Entries, probabilities over stringified labels
    assert "billing" in body["answers"]["department"]["probabilities"]


def test_model_allow_list(base_url):
    payload = valid_request()
    payload["model"] = "XHToken/Spark-X2.5"  # explicitly accepted canonical name
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 200 and body["model"] == "toy-resolved"
    payload["model"] = "gpt-4"  # unknown -> fail closed
    status, _, body = call(base_url, "/v1/systemone", payload)
    assert status == 422
    assert body["detail"][0]["loc"] == ["body", "model"]
    assert "Unknown model: gpt-4" in body["detail"][0]["msg"]
    payload["model"] = "jev-latest"  # alias accepted
    status, _, _ = call(base_url, "/v1/systemone", payload)
    assert status == 200


def test_jev_latest_accepted_even_with_custom_aliases(custom_alias_url):
    status, _, body = call(custom_alias_url, "/v1/models")
    assert status == 200
    names = {model["name"] for model in body["models"]}
    assert {"custom-alias", "jev-latest"} <= names
    payload = valid_request()  # model = jev-latest -> resolves to the loaded model
    status, _, body = call(custom_alias_url, "/v1/systemone", payload)
    assert status == 200 and body["model"] == "toy-resolved"
    payload["model"] = "jev-preview"  # overridden away -> rejected
    status, _, _ = call(custom_alias_url, "/v1/systemone", payload)
    assert status == 422


def test_non_json_body_is_json_invalid(base_url):
    request = urllib.request.Request(
        f"{base_url}/v1/systemone", data=b"{not json",
        headers={"Content-Type": "application/json", "Authorization": "Bearer secret-key"})
    try:
        urllib.request.urlopen(request, timeout=10)
        raise AssertionError("expected 422")
    except urllib.error.HTTPError as exc:
        body = json.loads(exc.read())
        assert exc.code == 422 and body["detail"][0]["type"] == "json_invalid"
