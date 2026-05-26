#!/bin/bash
# Claude Code Telegram bot launcher
# Copy to ~/bin/claude-<botname>.sh, fill in the variables, chmod +x.
#
# This file is launched by the systemd user service (claude-<botname>.service)
# under a non-interactive shell, so we cannot rely on ~/.bashrc being sourced.
# That is why PATH is set explicitly below — in particular, $HOME/.bun/bin must
# come first so the bun-installed `claude` binary is found.

# --- Configure these ---
BOT_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
STATE_DIR="/home/homelab/.claude/channels/telegram-mybot"
WORKDIR="/home/homelab/mybot"
SCREEN_NAME="mybot_bot"   # convention: <tag>_bot
BOT_TAG="mybot"
# ----------------------

export TELEGRAM_BOT_TOKEN="$BOT_TOKEN"
export TELEGRAM_STATE_DIR="$STATE_DIR"
export CLAUDE_BOT_TAG="$BOT_TAG"

# Claude Code is installed via `bun install -g @anthropic-ai/claude-code`,
# which puts the binary at $HOME/.bun/bin/claude (a symlink into
# $HOME/.bun/install/global/node_modules/@anthropic-ai/claude-code-linux-x64/claude).
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

mkdir -p "$STATE_DIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

exec screen -S "$SCREEN_NAME" -D -m \
  claude --dangerously-skip-permissions \
         --model sonnet \
         --channels plugin:telegram@claude-plugins-official
