#!/usr/bin/env bash
# Build a player machine from nothing: setup-player.sh claude|codex|gemini|grok
# Installs the agent's CLI. Signing in is a separate, one-time step per machine (see README).
set -euo pipefail
agent="${1:?usage: setup-player.sh claude|codex|gemini|grok}"
command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
command -v python3 >/dev/null || { apt-get update -q && apt-get install -y -q python3; }
need_node() { command -v npm >/dev/null || { echo "needs Node.js 20+ (npm)"; exit 1; }; }
case "$agent" in
  claude) command -v claude >/dev/null || { need_node; npm i -g @anthropic-ai/claude-code; } ;;
  codex)  need_node; npm i -g @openai/codex ;;
  gemini) need_node; npm i -g @google/gemini-cli ;;
  grok)   curl -fsSL https://x.ai/cli/install.sh | bash ;;
  *) echo "unknown agent: $agent"; exit 1 ;;
esac
echo "player machine ready for $agent. Sign in once, then run player.py (see arena/README.md)."
