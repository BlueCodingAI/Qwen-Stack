"""End-to-end: chat + tool call. Handles the SDK's wrapped response shape."""
import asyncio, json, sys, time
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
from vastai import Serverless

ENDPOINT, MODEL = "qwen38-bf16", "qwen38-27b-heretic"

TOOLS = [{"type": "function", "function": {
    "name": "read_file", "description": "Read a file from disk",
    "parameters": {"type": "object",
                   "properties": {"path": {"type": "string", "description": "file path"}},
                   "required": ["path"]}}}]

def body(r):
    """SDK may return the body merged, or only inside 'text' as a JSON string."""
    if isinstance(r, dict):
        if "choices" in r:
            return r
        if isinstance(r.get("text"), str):
            try:
                return json.loads(r["text"])
            except Exception:
                pass
    return r

async def main():
    c = Serverless(); ep = await c.get_endpoint(name=ENDPOINT)

    t = time.time()
    r = body(await ep.request("/v1/chat/completions", {
        "model": MODEL, "max_tokens": 64, "temperature": 0,
        "messages": [{"role": "user", "content": "Reply with exactly: OK"}]}, cost=64, timeout=900))
    ch = r.get("choices")
    print(f"[1] chat ({time.time()-t:.1f}s):", ch[0]["message"].get("content") if ch else f"NO CHOICES -> {str(r)[:200]}")
    if r.get("timings"):
        print(f"    {r['timings'].get('predicted_per_second',0):.1f} tok/s gen, "
              f"{r['timings'].get('prompt_per_second',0):.0f} tok/s prompt")

    t = time.time()
    r = body(await ep.request("/v1/chat/completions", {
        "model": MODEL, "max_tokens": 256, "temperature": 0, "tools": TOOLS,
        "messages": [{"role": "user", "content": "Read the file /etc/hostname using the read_file tool."}]},
        cost=256, timeout=900))
    ch = r.get("choices")
    if not ch:
        print("[2] tools: NO CHOICES ->", str(r)[:250]); await c.close(); return
    m = ch[0]["message"]; tc = m.get("tool_calls")
    print(f"[2] tools ({time.time()-t:.1f}s):", json.dumps(tc, indent=2)[:400] if tc
          else f"NO TOOL CALL -> content={str(m.get('content'))[:200]}")
    print("\nRESULT:", "TOOL CALLING OK" if tc else "TOOL CALLING FAILED")
    await c.close()

asyncio.run(main())
