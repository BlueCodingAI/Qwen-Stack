# Running the Qwen stack on an Ubuntu VPS

The `.sh` scripts are twins of the `.ps1` ones — same chain, same containers,
same billing behaviour. `normalize_proxy.py` is shared as-is;
`tunnel_supervisor.py` is shared too and picks its behaviour from `VAST_MODE`
(`serverless` or `direct`), which the start scripts set for you.

| Windows                   | Ubuntu                    | what it does                                  |
|---------------------------|---------------------------|-----------------------------------------------|
| `.\start-qwen.ps1`        | `./start-qwen.sh`         | serverless: bring the stack up                |
| `.\stop-qwen.ps1`         | `./stop-qwen.sh`          | serverless: stop GPU billing, keep the disk   |
| `.\stop-qwen-full.ps1`    | `./stop-qwen-full.sh`     | serverless: destroy everything on the account |
| `.\start-qwen-direct.ps1` | `./start-qwen-direct.sh`  | direct: rent one instance yourself            |
| `.\stop-qwen-direct.ps1`  | `./stop-qwen-direct.sh`   | direct: destroy that one instance             |
| `. .\use-qwen.ps1`        | `source ./use-qwen.sh`    | point *this shell's* Claude Code at Qwen      |

## Two ways to get a GPU

Both end at the same place - LiteLLM on :4000, the normalization proxy on :8100,
an SSH tunnel to llama-server on :18000 - and both build the container from the
same template hash. They differ in who owns the machine, and currently also in
which weights the container downloads (see below).

**Serverless** (`start-qwen.sh`): an endpoint plus a workergroup, and Vast's
autoscaler creates the worker. It scales to zero after ~15 min idle, which also
means it disappears mid-session and has to be woken again.

**Direct** (`start-qwen-direct.sh`): you rent one ordinary instance, it stays
yours until you destroy it, and `stop-qwen-direct.sh` destroys it. Nothing
scales it away, nothing wakes it for you, and once it is gone the bill is $0.
Prefer this if you want billing you can reason about in one line.

```bash
./start-qwen-direct.sh --dry-run   # print the offer it would rent, bill nothing
./start-qwen-direct.sh             # rent the cheapest match, bring the stack up
source ./use-qwen.sh && claude
./stop-qwen-direct.sh              # destroy it   -> $0.00/hr and $0/month
./stop-qwen-direct.sh --keep-disk  # only stop it -> $0.00/hr, ~$21/month standby
```

`--keep-disk` keeps the 56 GB of weights, so the next start is a ~24s restart
instead of a ~2-3 min re-download. Without it the instance is gone completely.

The direct scripts only ever touch **their own** instance - the id in
`.run/instance_id`, or one labelled `qwen-direct`. Anything else on the account
is reported and left alone. The two serverless stop scripts are the opposite:
`stop-qwen.sh` stops *every* instance on the account and `stop-qwen-full.sh`
destroys *every* instance — including one you rented in direct mode. If you use
both modes, stop each with its own script.

Re-running `start-qwen-direct.sh` reuses a running instance and restarts a
stopped one; it never rents a second GPU. Otherwise direct mode runs the same
three local services, so `.run/*.log`, re-run safety and the port-forwarding
advice below all apply unchanged.

Useful knobs (env vars): `QWEN_DISK` (default 160 GB), `QWEN_LABEL`,
`QWEN_SEARCH` (the offer query), `QWEN_TEMPLATE`, and `--offer <id>` to pin one
specific machine.

### Which model each mode runs

| mode | weights | set where |
|---|---|---|
| direct | `huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF` — `Huihui-Qwen3.8-27B-abliterated-bf16.gguf` (54.7 GB) + `mmproj-model-bf16.gguf` (0.93 GB) | `onstart-direct.sh`, in this repo |
| serverless | `0bserverx/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF` — `RVN-BF16.gguf` (53.8 GB) | the onstart baked into template `ad7f44ce...`, in the Vast console |

`vastai create instance` accepts `--onstart`, so direct mode replaces the
template's onstart with `onstart-direct.sh` and picks its own weights.
`vastai create workergroup` takes only `--template_hash`, so serverless has no
such hook and keeps running whatever the template says. Editing the template's
onstart in the Vast console (or pointing `$TEMPLATE` at a new template) is the
only way to move serverless onto the same model.

Both are BF16 Qwen3.8-27B abliterated builds of the same `qwen35` architecture
with the same 262,144-token trained context, so the sizing, flags and proxy
workarounds are identical - the huihui pair is just ~1.2 GB larger on disk and
in VRAM, which the 80 GB floor already covers.

## One-time setup

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip openssh-client curl procps

git clone <this repo> ~/qwen-stack && cd ~/qwen-stack
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip
pip install vastai 'litellm[proxy]' fastapi uvicorn httpx

vastai set api-key <YOUR_KEY>          # writes ~/.config/vastai/vast_api_key

# the key the workers accept, same one the Windows box uses
install -m 600 /path/to/runpod_key ~/.ssh/runpod_key

chmod +x *.sh
```

`start-qwen.sh` refuses to run until `vastai`, `python3`, `litellm`, `ssh`,
`curl` and `pgrep` are all on `PATH`, so activate the venv first (or add
`~/qwen-stack/.venv/bin` to `PATH` in `~/.bashrc`).

## Daily use

```bash
source .venv/bin/activate
./start-qwen.sh                  # serverless; ~$1.20/hr starts here
source ./use-qwen.sh && claude   # this shell now talks to Qwen
./stop-qwen.sh                   # GPU billing stops; disk (~$21/mo) keeps the model
```

or, renting the instance yourself:

```bash
./start-qwen-direct.sh           # rents one instance, prints its id and $/hr
source ./use-qwen.sh && claude
./stop-qwen-direct.sh            # destroys it - nothing left billing
```

Unlike the Windows version there are no minimized windows. Each service is a
`nohup`'d background process, so it survives an SSH disconnect:

```bash
tail -f .run/supervisor.log      # worker wake-ups, tunnel rebuilds
tail -f .run/litellm.log
cat .run/*.pid                   # what stop-qwen.sh will kill
```

`.run/` holds the pids and logs and is gitignored. Re-running `start-qwen.sh`
is safe: anything already healthy is reused rather than started twice.

## Using it from your laptop

Every service binds `127.0.0.1` deliberately. LiteLLM accepts a dummy token, so
binding it to `0.0.0.0` on a public VPS would publish an unauthenticated gateway
to a GPU you are paying for. Keep it on loopback and forward the port instead:

```bash
# on the laptop
ssh -N -L 4000:127.0.0.1:4000 user@your-vps &
source ./use-qwen.sh && claude          # or the .ps1 on Windows
```

## Optional: bring it up on boot

`start-qwen.sh` rents a GPU, so only do this if you want the VPS billing from
the moment it boots.

```ini
# /etc/systemd/system/qwen-stack.service
[Unit]
Description=Qwen stack (LiteLLM -> normalize proxy -> Vast tunnel)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=ubuntu
WorkingDirectory=/home/ubuntu/qwen-stack
Environment=PATH=/home/ubuntu/qwen-stack/.venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/ubuntu/qwen-stack/start-qwen.sh
ExecStop=/home/ubuntu/qwen-stack/stop-qwen.sh
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now qwen-stack
curl -s localhost:4000/health/liveliness   # verify before trusting a reboot
```

Verify it once by hand: the services are backgrounded children, and how long
systemd leaves them in the unit's cgroup depends on your systemd version. If
they get reaped when `ExecStart` returns, run the scripts by hand instead.

## Troubleshooting

| symptom | cause |
|---|---|
| `bad interpreter: /usr/bin/env bash^M` | file arrived with CRLF — `sed -i 's/\r$//' *.sh` (`.gitattributes` prevents this on a fresh clone) |
| `Permissions 0644 ... are too open` | `chmod 600 ~/.ssh/runpod_key` — `start-qwen.sh` does this for you |
| `tunnel :18000 never came up` | check `.run/supervisor.log`; a cold worker re-downloads 51 GB |
| `litellm :4000 died on startup` | port already taken, or the venv is not active — the script tails the log for you |
| direct: `tunnel :18000 never came up` on a fresh rental | the container is still pulling; `vastai logs <id>` shows llama-server's own output. If that template ever stops serving :18000, set `QWEN_IMAGE` + `QWEN_ONSTART` to launch a plain container instead |
| direct: "no instance of ours found" | already destroyed, or `.run/instance_id` is gone and the instance has no `qwen-direct` label — `vastai show instances` lists what is actually billing |
