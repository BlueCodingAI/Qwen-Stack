# onstart for DIRECT mode - handed to `vastai create instance --onstart`.
#
# This is the onstart belonging to template ad7f44ce435d59f8dfd2a16af201ff37 with
# one thing added at the top: a loop that repairs /root/.ssh/authorized_keys.
#
# Why it is needed. Vast writes that file owned by a non-root uid (observed as
# 113:988) with mode 644, and sshd then refuses every key under StrictModes:
#
#     Authentication refused: bad ownership or modes for file /root/.ssh/authorized_keys
#     Failed publickey for root from ::1 ... ED25519 SHA256:8B99xRQ...
#
# tunnel_supervisor therefore never got a tunnel, and because it discarded ssh's
# stderr the whole stack presented as a tunnel that "did not come up" while
# llama-server was in fact healthy and serving on :18000 the entire time.
#
# It cannot be repaired from outside the container: `vastai execute` runs only on
# stopped instances and its whitelist is roughly ls/rm (no chown, chmod, cp or
# mv), and `vastai attach ssh` reports the key as already associated without
# re-pushing it into a running container. Keys are injected around container
# start, so this is the one place the fix can live - and it loops rather than
# running once because the injection can happen after onstart begins.
#
# Keep this in step with $TEMPLATE / QWEN_TEMPLATE in start-qwen-direct.{ps1,sh}:
# --onstart REPLACES the template's own onstart rather than adding to it, so the
# body below has to track the template except where noted.
#
# Deliberate deviations from the template, both marked inline below:
#   1. the authorized_keys repair loop above.
#   2. llama-server runs -c 262144 instead of -c 131072. Claude Code packs prompts
#      well past 128K (an observed request was 156,383 tokens) and llama-server
#      rejects the whole request rather than truncating:
#        "request (156383 tokens) exceeds the available context size (131072)"
#      262144 is the model's own trained context_length from the gguf header, and
#      the extra 8 GiB of KV cache still leaves ~10 GiB free on an 80 GiB card.

(
  while true; do
    [ -d /root/.ssh ] && chmod 700 /root/.ssh 2>/dev/null
    if [ -e /root/.ssh/authorized_keys ]; then
      chown 0:0 /root/.ssh/authorized_keys 2>/dev/null
      chmod 600 /root/.ssh/authorized_keys 2>/dev/null
    fi
    sleep 10
  done
) >/dev/null 2>&1 &

# ---- from template ad7f44ce435d59f8dfd2a16af201ff37 (see deviations above) ----
export HF_TOKEN="${HF_TOKEN:-1}"
exec > >(tee -a /var/log/onstart.log > /proc/1/fd/1) 2>&1
echo "[onstart] BEGIN $(date -Is)"

mkdir -p /var/log/portal /workspace/models
: > /var/log/portal/llama.log

# The image launcher (/opt/supervisor-scripts/llama.sh) always runs
#   llama-server -hf "$LLAMA_MODEL" $LLAMA_ARGS
# so a local path cannot be used through it, and its single-stream -hf fetch measured
# ~40 Mbps -> far past the autoscaler's ~940 s deadline. Leave LLAMA_MODEL unset (the
# launcher then exits harmlessly), prefetch via hf_transfer, run llama-server ourselves.
LLAMA_BIN=/opt/llama.cpp/cuda-12.8
export LD_LIBRARY_PATH="$LLAMA_BIN:${LD_LIBRARY_PATH:-}"   # else libllama-server-impl.so not found

MODEL=/workspace/models/RVN-BF16.gguf
MMPROJ=/workspace/models/mmproj-Qwen3.8-27B-Q8_0.gguf

(
  pip install -q --no-cache-dir hf_transfer 'huggingface_hub[cli]' 2>&1 | tail -1
  export HF_HUB_ENABLE_HF_TRANSFER=1

  echo "[onstart] DOWNLOAD START $(date -Is)"
  S=$(date +%s)
  # one --include per pattern: positional args after REPO are read as explicit filenames
  hf download 0bserverx/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF \
      --include "RVN-BF16.gguf" \
      --include "mmproj-Qwen3.8-27B-Q8_0.gguf" \
      --local-dir /workspace/models
  E=$(date +%s)
  B=$(du -sb /workspace/models | cut -f1)
  echo "[onstart] DOWNLOAD DONE secs=$((E-S)) bytes=$B"
  python3 -c "print(f'[onstart] RATE {$B/1e9:.1f} GB in {$E-$S}s = {$B*8/1e6/max($E-$S,1):.0f} Mbps')"
  ls -la "$MODEL" "$MMPROJ" 2>&1 | tail -3

  echo "[onstart] starting llama-server $(date -Is)"
  # deviation 2: -c is 262144 here, the template has 131072. See the header.
  # (A comment cannot go on the -c line itself - it would terminate the
  #  backslash continuation and detach the pipeline on the last line.)
  "$LLAMA_BIN/llama-server" \
    -m "$MODEL" --mmproj "$MMPROJ" \
    --alias qwen38-27b-heretic \
    --host 127.0.0.1 --port 18000 \
    -c 262144 -ngl 999 --jinja -fa on --metrics \
    2>&1 | tee -a /var/log/portal/llama.log > /proc/1/fd/1
) &

bootstrap_script=https://raw.githubusercontent.com/vast-ai/pyworker/refs/heads/main/start_server.sh;
curl -L "$bootstrap_script" | bash;
