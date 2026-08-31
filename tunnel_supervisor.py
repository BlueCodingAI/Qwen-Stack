"""Keeps a fast path to llama-server alive across Vast scale-to-zero events.

Design: Vast's routing SDK does a lookup per request against an API limited to
1 req/sec, so using it for inference adds a random 1-18s (HTTP 429 + backoff).
An SSH tunnel straight to llama-server is a steady ~1.1s -- but it dies whenever
the endpoint scales to zero (15 min idle), taking the worker with it.

So: use the router for exactly one thing (waking a cold worker), and the tunnel
for all inference. This process watches the tunnel and rebuilds it when needed.

Two modes, chosen by VAST_MODE:

  serverless (default) - the endpoint's autoscaler owns the worker. If no worker
                         exists, wake one through the router (one call, then the
                         tunnel takes over).
  direct               - you own one specific instance (VAST_INSTANCE_ID). Never
                         calls the router and never creates anything: a missing
                         instance is reported, not silently re-rented. Restarting
                         a stopped instance is still allowed, since that is the
                         instance you already pay disk for.

Run it once and leave it running; LiteLLM points at 127.0.0.1:18000.
"""
import asyncio, json, os, subprocess, sys, time, urllib.request

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

ENDPOINT  = os.environ.get("VAST_ENDPOINT", "qwen38-bf16")
MODEL     = os.environ.get("SHIM_MODEL_ID", "qwen38-27b-heretic")
LOCAL_PORT= 18000
SSH_KEY   = os.path.expanduser(os.environ.get("VAST_SSH_KEY", "~/.ssh/runpod_key"))
CHECK_SEC = 15

DIRECT      = os.environ.get("VAST_MODE", "serverless").strip().lower() == "direct"
INSTANCE_ID = os.environ.get("VAST_INSTANCE_ID", "").strip()

def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

def tunnel_ok() -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{LOCAL_PORT}/health", timeout=4) as r:
            return r.status == 200
    except Exception:
        return False

def instances():
    try:
        out = subprocess.run(["vastai", "show", "instances", "--raw", "--full"],
                             capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except Exception as e:
        log(f"instance lookup failed: {e}")
        return []

def mine(i):
    """In direct mode we drive exactly one instance; anything else on the account
    (another experiment, another project) is none of our business."""
    return not INSTANCE_ID or str(i.get("id")) == INSTANCE_ID

def running_worker():
    """Returns (ssh_host, ssh_port) for a running instance, else None."""
    for i in instances():
        if mine(i) and i.get("actual_status") == "running" and i.get("ssh_host"):
            return i["ssh_host"], i["ssh_port"]
    return None

def stopped_instance():
    """A stopped instance still holds the 51 GB model, so restarting it (~24s) is far
    cheaper than a router wake that may rebuild from scratch (~2-3 min)."""
    for i in instances():
        if mine(i) and i.get("actual_status") in ("exited", "stopped"):
            return i.get("id")
    return None

async def wake():
    """One router call. Blocks until a worker actually answers (cold start ~2 min)."""
    from vastai import Serverless          # serverless mode only
    c = Serverless()
    try:
        ep = await c.get_endpoint(name=ENDPOINT)
        await ep.request("/v1/chat/completions",
            {"model": MODEL, "max_tokens": 8, "temperature": 0,
             "messages": [{"role": "user", "content": "hi"}]},
            cost=8, timeout=1800)
    finally:
        await c.close()

def start_tunnel(host, port):
    cmd = ["ssh", "-i", SSH_KEY, "-p", str(port), f"root@{host}", "-N",
           "-L", f"{LOCAL_PORT}:127.0.0.1:{LOCAL_PORT}",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=20",
           "-o", "ServerAliveCountMax=3"]
    log(f"opening tunnel -> {host}:{port}")
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def main():
    proc = None
    if DIRECT:
        log(f"supervising tunnel on :{LOCAL_PORT} for instance {INSTANCE_ID or '(any)'} [direct]")
    else:
        log(f"supervising tunnel on :{LOCAL_PORT} for endpoint '{ENDPOINT}' [serverless]")
    while True:
        if tunnel_ok():
            time.sleep(CHECK_SEC); continue

        log("tunnel down")
        if proc and proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=10)
            except Exception: proc.kill()
            proc = None

        w = running_worker()
        if not w:
            sid = stopped_instance()
            if sid:
                log(f"instance {sid} is stopped - restarting it (disk retained, ~24s)")
                subprocess.run(["vastai", "start", "instance", str(sid)],
                               capture_output=True, text=True, timeout=120)
            elif DIRECT:
                # Creating an instance here would start billing behind your back.
                log(f"no instance{' ' + INSTANCE_ID if INSTANCE_ID else ''} - it was destroyed "
                    f"or never created. Run start-qwen-direct.sh; waiting.")
                time.sleep(20); continue
            else:
                log("no instance at all - waking via router (full cold start, ~2-3 min)")
                try:
                    asyncio.run(wake())
                except Exception as e:
                    log(f"wake failed: {e}; retrying"); time.sleep(20); continue
            for _ in range(40):
                w = running_worker()
                if w: break
                time.sleep(5)
            if not w:
                log("worker never appeared; retrying"); continue

        proc = start_tunnel(*w)
        for _ in range(20):
            time.sleep(3)
            if tunnel_ok():
                log("tunnel healthy"); break
        else:
            log("tunnel did not come up; will retry")

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: log("stopped")
