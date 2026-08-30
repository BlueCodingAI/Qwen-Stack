# Running the Qwen stack on an Ubuntu VPS

The `.sh` scripts are twins of the `.ps1` ones — same chain, same endpoint, same
billing behaviour. `tunnel_supervisor.py` and `normalize_proxy.py` are unchanged;
they were already cross-platform.

| Windows              | Ubuntu                  | what it does                                     |
|----------------------|-------------------------|--------------------------------------------------|
| `.\start-qwen.ps1`   | `./start-qwen.sh`       | bring the stack up (~24s warm, ~2-3 min cold)     |
| `.\stop-qwen.ps1`    | `./stop-qwen.sh`        | stop GPU billing, keep the 51 GB model on disk    |
| `.\stop-qwen-full.ps1` | `./stop-qwen-full.sh` | destroy everything, pay nothing between sessions  |
| `. .\use-qwen.ps1`   | `source ./use-qwen.sh`  | point *this shell's* Claude Code at Qwen          |

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
./start-qwen.sh                  # ~$1.20/hr starts here
source ./use-qwen.sh && claude   # this shell now talks to Qwen
./stop-qwen.sh                   # GPU billing stops; disk (~$21/mo) keeps the model
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
