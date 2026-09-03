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

It also watches the two local services below the tunnel:

    LiteLLM :4000  ->  normalize_proxy :8100  ->  tunnel :18000

Only the tunnel used to be supervised. A proxy that died therefore left the
tunnel healthy and every request failing at LiteLLM with

    Hosted_vllmException - Cannot connect to host 127.0.0.1:8100

until someone noticed and restarted it by hand. Both local services are now
restarted the same way the tunnel is. Set QWEN_MANAGE_SERVICES=0 for the old
tunnel-only behaviour.

Run it once and leave it running; LiteLLM points at 127.0.0.1:18000.
"""
import asyncio, atexit, json, os, shutil, signal, socket, subprocess, sys, time
import urllib.error, urllib.request

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

HERE = os.path.dirname(os.path.abspath(__file__))
RUN  = os.path.join(HERE, ".run")
os.makedirs(RUN, exist_ok=True)

ENDPOINT  = os.environ.get("VAST_ENDPOINT", "qwen38-bf16")
MODEL     = os.environ.get("SHIM_MODEL_ID", "qwen38-27b-heretic")
LOCAL_PORT= 18000
SSH_KEY   = os.path.expanduser(os.environ.get("VAST_SSH_KEY", "~/.ssh/runpod_key"))
CHECK_SEC = 15

DIRECT      = os.environ.get("VAST_MODE", "serverless").strip().lower() == "direct"
INSTANCE_ID = os.environ.get("VAST_INSTANCE_ID", "").strip()
MANAGE      = os.environ.get("QWEN_MANAGE_SERVICES", "1").strip().lower() not in ("0", "false", "no")


def log(m):
    line = f"[{time.strftime('%H:%M:%S')}] {m}"
    print(line, flush=True)
    # start-qwen*.ps1 gives this its own window and captures nothing, so without a
    # file there is no record of what the supervisor did once that window closes.
    try:
        with open(os.path.join(RUN, "supervisor.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


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


def worker_endpoints():
    """SSH endpoints for our running instance, best first, or None.

    Vast gives an instance two ways in: a proxy (sshN.vast.ai, the ssh_host /
    ssh_port fields) and usually a direct one (public_ipaddr plus whichever host
    port is mapped to container port 22). Only the proxy used to be tried, and a
    broken proxy accepts the TCP connection and then hangs up -

        Connection closed by 3.239.71.116 port 11982

    which from the outside is indistinguishable from a model that never came up.
    Direct goes first: it skips Vast's proxy entirely. The proxy stays as the
    fallback because some hosts are behind NAT and offer nothing else.
    """
    for i in instances():
        if not (mine(i) and i.get("actual_status") == "running"):
            continue
        eps = []
        mapped = (i.get("ports") or {}).get("22/tcp") or []
        host_port = mapped[0].get("HostPort") if mapped else None
        if i.get("public_ipaddr") and host_port:
            eps.append((str(i["public_ipaddr"]).strip(), int(host_port), "direct"))
        if i.get("ssh_host"):
            eps.append((i["ssh_host"], i["ssh_port"], "proxy"))
        if eps:
            return eps
    return None


def endpoint_ok(host, port) -> bool:
    """Can we actually log in here? Cheap probe so a dead endpoint is skipped
    rather than silently retried for the whole startup window."""
    try:
        r = subprocess.run(
            ["ssh", "-i", SSH_KEY, "-p", str(port), f"root@{host}",
             "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
             "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "true"],
            capture_output=True, timeout=40)
        return r.returncode == 0
    except Exception:
        return False


def pick_endpoint(eps):
    """First endpoint that actually accepts a login."""
    for host, port, kind in eps:
        if endpoint_ok(host, port):
            return host, port, kind
        log(f"ssh {kind} endpoint {host}:{port} refused - trying the next one")
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


def start_tunnel(host, port, kind="?"):
    cmd = ["ssh", "-i", SSH_KEY, "-p", str(port), f"root@{host}", "-N",
           "-L", f"{LOCAL_PORT}:127.0.0.1:{LOCAL_PORT}",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=20",
           "-o", "ServerAliveCountMax=3"]
    log(f"opening tunnel -> {host}:{port} [{kind}]")
    # ssh's stderr used to go to DEVNULL, which hid the one thing worth seeing.
    # A key Vast wrote as uid 113 rather than root, for instance, fails as
    # "Authentication refused: bad ownership or modes" and otherwise surfaces
    # only as an unexplained "tunnel did not come up" loop.
    err = open(os.path.join(RUN, "tunnel.log"), "ab")
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=err)


# --- local services below the tunnel --------------------------------------

def _proxy_cmd():
    return [sys.executable, "-m", "uvicorn", "normalize_proxy:app",
            "--host", "127.0.0.1", "--port", "8100", "--log-level", "info"]


def _litellm_cmd():
    exe = shutil.which("litellm")
    return ([exe] if exe else [sys.executable, "-m", "litellm"]) + \
           ["--config", "litellm_config.yaml", "--port", "4000"]


# grace = how long a freshly started process may take to answer before it counts
# as dead. LiteLLM really is slow to boot - the start scripts allow it 3 minutes -
# and judging it on the miss counter alone had the supervisor killing and
# respawning it mid-startup, over and over, so it never finished coming up.
SERVICES = [
    {"name": "proxy",   "port": 8100, "grace": 60,  "cmd": _proxy_cmd,
     "url": "http://127.0.0.1:8100/health"},
    {"name": "litellm", "port": 4000, "grace": 180, "cmd": _litellm_cmd,
     "url": "http://127.0.0.1:4000/health/liveliness"},
]
_procs    = {}  # name -> Popen of a service we started
_misses   = {}  # name -> consecutive failed checks
_seen     = {}  # name -> has it answered at least once since it was last started
_ready_at = {}  # name -> when a not-yet-seen service stops being "still booting"
_tunnel   = None


def answered(url) -> bool:
    """True if anything spoke HTTP at all, whatever the status.

    Deliberately not a 200 check: normalize_proxy reports the tunnel's health in
    its own /health and returns 503 whenever llama-server is unreachable. The
    proxy is perfectly alive in that case, so treating 503 as dead would restart
    a healthy proxy every time the GPU is cold - and restarting would fix
    nothing, since the fault is upstream."""
    try:
        urllib.request.urlopen(url, timeout=4)
        return True
    except urllib.error.HTTPError:
        return True          # responded, just not 200
    except Exception:
        return False         # refused, timed out, nothing listening


def port_free(port) -> bool:
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) != 0


def spawn(svc):
    """Start one service detached, output in .run/<name>.log and pid in
    .run/<name>.pid - the convention _common.sh already uses, so the stop
    scripts find it whether a start script or this supervisor launched it."""
    name = svc["name"]
    out = open(os.path.join(RUN, f"{name}.log"), "ab")
    kw = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" \
         else {"start_new_session": True}
    # Writing to a file rather than a console makes Python pick the locale codec
    # for stdout, and LiteLLM's non-ASCII startup banner then dies on cp1252 with
    # UnicodeEncodeError before it ever binds :4000.
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    p = subprocess.Popen(svc["cmd"](), cwd=HERE, stdin=subprocess.DEVNULL,
                         stdout=out, stderr=subprocess.STDOUT, env=env, **kw)
    with open(os.path.join(RUN, f"{name}.pid"), "w") as f:
        f.write(str(p.pid))
    _procs[name] = p
    return p


def check_services():
    """Restart a dead proxy or LiteLLM.

    Two guards stop this from fighting a service that is merely slow:

      * a startup grace, in force until the service has answered once. The start
        scripts launch these themselves, and LiteLLM can take well over a minute,
        so without it the supervisor kills and respawns it mid-boot forever.
      * two consecutive misses once it has been seen healthy, so one blocked
        check does not trigger a restart.
    """
    now = time.time()
    for svc in SERVICES:
        name = svc["name"]
        if answered(svc["url"]):
            if not _seen.get(name):
                log(f"{name} is up")
            elif _misses.get(name):
                log(f"{name} is back")
            _seen[name] = True
            _misses[name] = 0
            continue
        if not _seen.get(name) and now < _ready_at.get(name, 0):
            continue                     # still inside its startup window
        _misses[name] = _misses.get(name, 0) + 1
        if _misses[name] < 2:
            continue
        old = _procs.get(name)
        if old and old.poll() is None:
            old.terminate()
            try: old.wait(timeout=10)
            except Exception: old.kill()
        elif not port_free(svc["port"]):
            # Stopped answering but something still holds the port, and it is not
            # a process we started - the start scripts launch these too. Spawning
            # now would only lose the bind race and die, once every other check.
            log(f"{name} is not answering, but :{svc['port']} is still held by a "
                f"process we did not start - leaving it alone")
            _misses[name] = 0
            continue
        try:
            log(f"{name} is down - restarting (pid {spawn(svc).pid}, log .run/{name}.log)")
        except Exception as e:
            log(f"{name} restart failed: {e}")
        _misses[name] = 0
        _seen[name] = False                      # it has to prove itself again
        _ready_at[name] = time.time() + svc["grace"]


def shutdown(*_):
    """The stop scripts kill the supervisor before anything else, so it cannot
    resurrect a service between their two kills; take our children with us too,
    in case this process is stopped on its own.

    This cannot run under Stop-Process -Force on Windows, which is an uncatchable
    TerminateProcess - the kill ordering in the stop scripts is what actually
    guarantees the invariant."""
    for p in list(_procs.values()) + [_tunnel]:
        if p and p.poll() is None:
            try: p.terminate()
            except Exception: pass


atexit.register(shutdown)
for _sig in (signal.SIGTERM, signal.SIGINT):
    try: signal.signal(_sig, lambda *_: sys.exit(0))
    except Exception: pass


def main():
    global _tunnel
    if DIRECT:
        log(f"supervising tunnel on :{LOCAL_PORT} for instance {INSTANCE_ID or '(any)'} [direct]")
    else:
        log(f"supervising tunnel on :{LOCAL_PORT} for endpoint '{ENDPOINT}' [serverless]")
    if MANAGE:
        log("also watching proxy :8100 and litellm :4000")
        # The start script launches both of these moments after starting us, so
        # open each one's startup window now rather than judging it immediately.
        now = time.time()
        for svc in SERVICES:
            _ready_at[svc["name"]] = now + svc["grace"]
    while True:
        if tunnel_ok():
            if MANAGE: check_services()
            time.sleep(CHECK_SEC); continue

        log("tunnel down")
        if _tunnel and _tunnel.poll() is None:
            _tunnel.terminate()
            try: _tunnel.wait(timeout=10)
            except Exception: _tunnel.kill()
            _tunnel = None

        w = worker_endpoints()
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
                if MANAGE: check_services()
                time.sleep(20); continue
            else:
                log("no instance at all - waking via router (full cold start, ~2-3 min)")
                try:
                    asyncio.run(wake())
                except Exception as e:
                    log(f"wake failed: {e}; retrying")
                    if MANAGE: check_services()
                    time.sleep(20); continue
            for _ in range(40):
                w = worker_endpoints()
                if w: break
                time.sleep(5)
            if not w:
                log("worker never appeared; retrying"); continue

        ep = pick_endpoint(w)
        if not ep:
            log("no ssh endpoint accepted a login (see .run/tunnel.log); will retry")
            if MANAGE: check_services()
            time.sleep(15); continue
        host, port, kind = ep
        _tunnel = start_tunnel(host, port, kind)
        for _ in range(20):
            time.sleep(3)
            if tunnel_ok():
                log("tunnel healthy"); break
        else:
            log("tunnel did not come up; see .run/tunnel.log - will retry")
        if MANAGE: check_services()


if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: log("stopped")
