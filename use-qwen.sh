# Source this in a shell to point THAT shell's Claude Code at Qwen:
#     source ./use-qwen.sh && claude
# Other shells keep using your normal Claude subscription.
export ANTHROPIC_BASE_URL="http://127.0.0.1:4000"
export ANTHROPIC_AUTH_TOKEN="dummy"
export ANTHROPIC_MODEL="qwen38-27b-heretic"
# optional: also show it in the /model picker for this session
export ANTHROPIC_CUSTOM_MODEL_OPTION="qwen38-27b-heretic"
export ANTHROPIC_CUSTOM_MODEL_OPTION_NAME="Qwen3.8-27B (Vast)"
export ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION="Self-hosted BF16 - RTX PRO 6000"
printf '\033[32mThis shell now targets Qwen3.8-27B via localhost:4000\033[0m\n'
