"""Normalizes OpenAI-format requests for the Qwen3.8 chat template, then forwards
them to llama-server through the SSH tunnel.

    LiteLLM :4000  ->  this :8100  ->  tunnel :18000  ->  llama-server

This model's Jinja chat template is strict and raise_exception()s rather than
degrading, which surfaces as an opaque HTTP 500. Two known traps:

  * "System message must be at the beginning" - Claude Code sends a system prompt
    plus system-reminders; after LiteLLM's Anthropic->OpenAI translation, some land
    mid-array. We merge every system message into one at index 0.
  * "Unexpected reasoning effort high" - the template accepts only xhigh|medium|low.
    We remap high->xhigh and drop anything else unrecognized.
"""
import json, os
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

UPSTREAM = os.environ.get("UPSTREAM", "http://127.0.0.1:18000")
TIMEOUT  = float(os.environ.get("PROXY_TIMEOUT", "1800"))
EFFORT_MAP = {"high": "xhigh", "xhigh": "xhigh", "medium": "medium", "low": "low"}

app = FastAPI()
_client: httpx.AsyncClient | None = None

@app.on_event("startup")
async def _start():
    global _client
    _client = httpx.AsyncClient(base_url=UPSTREAM, timeout=TIMEOUT)

@app.on_event("shutdown")
async def _stop():
    if _client: await _client.aclose()

def _text(content):
    """OpenAI content may be a string or a list of typed parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content
                         if isinstance(p, dict) and p.get("type") == "text")
    return "" if content is None else str(content)

def normalize(body: dict) -> dict:
    msgs = body.get("messages")
    if isinstance(msgs, list) and msgs:
        systems = [m for m in msgs if m.get("role") == "system"]
        others  = [m for m in msgs if m.get("role") != "system"]
        if systems:
            merged = "\n\n".join(t for t in (_text(m.get("content")) for m in systems) if t)
            body["messages"] = [{"role": "system", "content": merged}] + others

    eff = body.get("reasoning_effort")
    if eff is not None:
        mapped = EFFORT_MAP.get(str(eff).lower())
        if mapped: body["reasoning_effort"] = mapped
        else:      body.pop("reasoning_effort", None)
    return body

@app.get("/health")
async def health():
    try:
        r = await _client.get("/health", timeout=5)
        return JSONResponse({"proxy": "ok", "upstream": r.status_code})
    except Exception as e:
        return JSONResponse({"proxy": "ok", "upstream": f"unreachable: {e}"}, status_code=503)

@app.get("/v1/models")
async def models():
    r = await _client.get("/v1/models")
    return JSONResponse(r.json(), status_code=r.status_code)

@app.post("/v1/chat/completions")
@app.post("/v1/completions")
async def chat(request: Request):
    body = normalize(await request.json())
    path = "/v1/chat/completions" if "messages" in body else "/v1/completions"

    if body.get("stream"):
        async def gen():
            async with _client.stream("POST", path, json=body) as r:
                async for chunk in r.aiter_raw():
                    yield chunk
        return StreamingResponse(gen(), media_type="text/event-stream")

    r = await _client.post(path, json=body)
    try:
        return JSONResponse(r.json(), status_code=r.status_code)
    except Exception:
        return JSONResponse({"error": {"message": r.text[:500]}}, status_code=r.status_code)
