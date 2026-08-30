# Dot-source this in a terminal to point THAT terminal's Claude Code at Qwen:
#     . .\use-qwen.ps1 ; claude
# Other terminals keep using your normal Claude subscription.
$env:ANTHROPIC_BASE_URL   = "http://127.0.0.1:4000"
$env:ANTHROPIC_AUTH_TOKEN = "dummy"
$env:ANTHROPIC_MODEL      = "qwen38-27b-heretic"
# optional: also show it in the /model picker for this session
$env:ANTHROPIC_CUSTOM_MODEL_OPTION             = "qwen38-27b-heretic"
$env:ANTHROPIC_CUSTOM_MODEL_OPTION_NAME        = "Qwen3.8-27B (Vast)"
$env:ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = "Self-hosted BF16 - RTX PRO 6000"
Write-Host "This terminal now targets Qwen3.8-27B via localhost:4000" -ForegroundColor Green
