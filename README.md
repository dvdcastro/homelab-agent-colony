# homelab-agent-colony

A recipe for running a persistent fleet of Claude Code Telegram bots on a Proxmox homelab — each bot with its own LXC, persona, memory, and SSH access to the cluster.

## What this is

Each bot in this setup is:
- A **Claude Code** instance running persistently via `screen` inside a `systemd` user service
- Connected to **Telegram** via the official `plugin:telegram@claude-plugins-official` channel plugin
- Given a **persona and skills** through a `CLAUDE.md` file in its working directory
- Capable of **SSH, file operations, API calls** — anything Claude Code can do, it can do autonomously

The bots are independent agents with different roles: personal coach, research assistant, daily companion, developer, trader, work organizer. They share infra (Proxmox cluster, Plane.so, a local LLM) but each has its own identity and memory.

## Architecture

```
Telegram
    │
    ▼
Claude Code (claude --channels plugin:telegram@claude-plugins-official)
    │  ├── CLAUDE.md        ← persona, skills, hard limits
    │  └── memory/          ← persistent memory files
    │
    ▼
screen session  ←── systemd user service (auto-restart, journald logs)
    │
    ▼
LXC / VM  (Ubuntu 24.04, homelab user)
    │
    ▼
Proxmox cluster  (SSH access, API, VM/LXC management)
```

**One bot = one LXC.** Each container gets:
- Ubuntu 24.04, 2–4 cores, 4–8 GB RAM
- `homelab` user with sudo
- [bun](https://bun.sh) installed (Claude Code ships as a bun-managed global package)
- Claude Code installed (`bun install -g @anthropic-ai/claude-code`)
- Telegram plugin installed (`claude plugin marketplace add anthropics/claude-plugins-official && claude plugins install telegram@claude-plugins-official`)
- A `TELEGRAM_STATE_DIR` on a persistent volume
- The systemd user service enabled at boot

## Files in this repo

| File | Description |
|------|-------------|
| `templates/claude-bot.sh` | Launcher script — sets env vars, starts `screen` with Claude Code |
| `templates/claude-bot.service` | systemd user service unit file |
| `templates/CLAUDE.md` | Example persona file — the "soul" of an agent |
| `docs/lessons-learned.md` | Gotchas: zombie ACPs, screen quirks, auth, permissions |

## Quick start

### 1. Install Claude Code (via bun)

Claude Code is distributed as a bun-managed global package. **Do not use `npm`** — the official install path is bun, which drops a single statically-linked binary onto disk and handles updates cleanly.

```bash
# Install bun (single-user, no sudo needed)
curl -fsSL https://bun.sh/install | bash

# Make sure bun is on your PATH for future shells.
# The installer appends this to ~/.bashrc — verify it's there:
#
#   export BUN_INSTALL="$HOME/.bun"
#   export PATH="$BUN_INSTALL/bin:$PATH"
#
# Then either restart your shell or `source ~/.bashrc`.

# Install Claude Code globally
bun install -g @anthropic-ai/claude-code

# Verify
claude --version
which claude   # → /home/homelab/.bun/bin/claude
```

The `claude` command lands at `~/.bun/bin/claude`, which is a symlink into
`~/.bun/install/global/node_modules/@anthropic-ai/claude-code-linux-x64/claude` (or the `-musl` variant on Alpine-style userlands). The launcher script in this repo puts `$HOME/.bun/bin` first on `PATH` so the bot always picks it up.

To update Claude Code later (do this regularly — releases ship weekly-ish):

```bash
bun update -g @anthropic-ai/claude-code
```

### 2. Install the Telegram plugin

```bash
# Must be done interactively (needs TTY)
claude plugin marketplace add anthropics/claude-plugins-official
claude plugins install telegram@claude-plugins-official
```

### 3. Authenticate Claude Code

```bash
# Also interactive — opens browser for OAuth
claude auth login
```

### 4. Create the launcher script

Copy `templates/claude-bot.sh` to `~/bin/claude-<botname>.sh`, fill in your bot token, and make it executable:

```bash
cp templates/claude-bot.sh ~/bin/claude-mybot.sh
chmod +x ~/bin/claude-mybot.sh
# Edit the file and replace BOT_TOKEN, STATE_DIR, WORKDIR, BOT_TAG
```

### 5. Set up the systemd user service

```bash
mkdir -p ~/.config/systemd/user
cp templates/claude-bot.service ~/.config/systemd/user/claude-mybot.service
# Edit the Description and ExecStart fields

# Enable and start
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
systemctl --user enable claude-mybot.service
systemctl --user start claude-mybot.service
```

### 6. Enable lingering (so the service survives logout)

```bash
sudo loginctl enable-linger homelab
```

### 7. Verify

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user status claude-mybot.service

# Peek at the screen session (don't attach — use hardcopy)
screen -S mybot_bot -X hardcopy /tmp/dump.txt && cat /tmp/dump.txt
```

## Giving the bot its persona

The `CLAUDE.md` file in the bot's working directory is loaded by Claude Code at startup. It defines everything:

```
/home/homelab/mybot/
└── CLAUDE.md     ← persona, skills, hard limits, context
```

See `templates/CLAUDE.md` for an annotated example. Keep it focused:
- Who the bot is (name, personality, communication style)
- What it can do (skills, tools, allowed operations)
- What it must never do (hard limits)
- Relevant context (user profile, recurring tasks, API endpoints)

## What can you build with this?

Each bot is a Claude Code instance with a `CLAUDE.md` persona — so the question is really: what do you want an AI agent to do for you, persistently, over Telegram? Some ideas:

| Type | Example agent |
|------|--------------|
| **Infrastructure** | Cluster admin that watches your Proxmox nodes, restarts services, reports alerts, and runs upgrades on request |
| **Dev assistant** | Codebase-aware bot scoped to a specific project — reviews PRs, runs tests, explains errors, generates boilerplate |
| **Research** | Deep-analysis agent that searches, summarizes, and saves findings to markdown files in your repo |
| **Personal productivity** | Work organizer with access to your calendar, task list, and notes — GTD-style triage over Telegram |
| **Domain specialist** | Finance, legal, health, cooking — give it a knowledge base and a persona, and it becomes a focused expert |
| **Trading / automation** | Bot that monitors APIs, executes logic on a schedule, and reports back with summaries |
| **Education** | Study companion scoped to a course or topic, with memory of what you've already covered |
| **Family assistant** | General-purpose helper for a household member, with context about their routines and preferences |

The pattern scales: one bot per concern, one LXC per bot, one `CLAUDE.md` per identity. Add a new bot in ~15 minutes.

Some patterns worth stealing:
- **One Telegram bot account per agent.** Lets you revoke compromised tokens independently and gives each agent a distinct identity in the user's chat list.
- **One LXC per agent, where feasible.** Memory isolation, independent crash domain, easy to retire/rebuild.
- **Shared SSH key across infra.** All bots can SSH to all nodes as the same user — makes cross-machine work possible without per-bot key sprawl. (Trade-off: rotate everywhere if one LXC is compromised.)
- **One canonical inventory doc** listing every service, hostname, and bot account. Without it you lose track at ~5 bots.

## Managing the fleet

```bash
# Check all bots on a node
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user list-units 'claude-*.service'

# Restart a bot
systemctl --user restart claude-mybot.service

# View logs
journalctl --user -u claude-mybot.service -f

# See live screen output without attaching
screen -S mybot_bot -X hardcopy /tmp/dump.txt && cat /tmp/dump.txt

# Send a message to the bot's terminal (careful)
screen -S mybot_bot -X stuff 'your message here\n'

# Update Claude Code on a bot LXC (run as the homelab user)
bun update -g @anthropic-ai/claude-code
systemctl --user restart claude-mybot.service
```

## The TELEGRAM_STATE_DIR matters

The state directory stores the conversation history. It survives service restarts. If a bot gets stuck (corrupted `previous_message_id` error), you can reset it:

```bash
# Back up and clear the conversation state
cd ~/.claude/projects/<project-dir>/
mv <session-id>.jsonl <session-id>.jsonl.bak
rm -f ~/telegram-state/inbox/*
systemctl --user restart claude-mybot.service
```

## Costs (approximate, Bogotá homelab)

| Component | Monthly cost |
|-----------|-------------|
| 3× HP EliteDesk/ProDesk Mini (used) | ~$0 after purchase |
| Electricity (≈200W avg) | ~$15 USD |
| Claude Max subscription | ~$100 USD |
| Internet | already paying |
| **Total** | **~$115 USD/month** |

vs. equivalent cloud: 3× 4-core / 64GB VMs ≈ $600–800 USD/month

## Lessons learned

See [`docs/lessons-learned.md`](docs/lessons-learned.md) for the full list. Quick hits:

- **`claude auth login` cannot be automated** — it opens a browser for OAuth. You must SSH in and do it manually the first time.
- **Plugin install order matters**: marketplace first, then `claude plugins install`.
- **Never give a bot `sudo` without an allowlist** — it will use it.
- **`pct exec` vs `pct enter`**: use `pct enter` for interactive sessions (TTY required for auth), `pct exec` for scripted commands.
- **3 GB RAM sessions are normal** after a few days — build a weekly restart cron.

## Related

- [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
- [claude-plugins-official](https://github.com/anthropics/claude-plugins-official)
- Presented at [AI Tinkerers Bogotá](https://bogota.aitinkerers.org) — May 2026

---

Built by [@dvdcastro](https://github.com/dvdcastro) in Bogotá, Colombia.
