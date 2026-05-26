# Lessons Learned — Claude Code Bot Fleet on Proxmox

Hard-won knowledge from running 13 Claude Code bots on a 3-node Proxmox cluster.

---

## Authentication

### `claude auth login` cannot be automated

OAuth opens a browser. You must SSH in interactively (with a real TTY) and complete the flow yourself the first time on each machine.

```bash
# On the LXC directly (requires TTY — use pct enter, not pct exec)
pct enter <LXC_ID>
su - homelab
claude auth login
# Follow the browser link, paste the code back
```

If you try to automate this with `pct exec` or a background script, it will hang silently. It needs a TTY.

### Plugin install order matters

On a fresh LXC, you must install the marketplace before the plugin:

```bash
# Step 1 — add the official marketplace (only needed once per machine)
claude plugin marketplace add anthropics/claude-plugins-official

# Step 2 — install the Telegram plugin
claude plugins install telegram@claude-plugins-official
```

If you skip step 1 and only run step 2, the plugin installs but Claude Code can't find it at runtime. The bot starts but never receives Telegram messages.

---

## Telegram plugin

### Set up access.json before first use

The Telegram plugin uses an allowlist in `$TELEGRAM_STATE_DIR/access.json`. Without it, the bot ignores all messages.

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["YOUR_TELEGRAM_USER_ID"],
  "groups": {},
  "pending": {}
}
```

Find your Telegram user ID: message `@userinfobot` on Telegram.

### The `previous_message_id` corruption bug

After a long session, Claude Code can get stuck in a loop:

```
API Error: 400 diagnostics.previous_message_id: must be the `id` from a prior /v1/messages response
```

Every new message fails. The process is alive but deaf. Fix:

```bash
# 1. Find the active session file (largest/most recent .jsonl)
ls -lt ~/.claude/projects/<project-dir>/*.jsonl

# 2. Back it up and remove it
mv <session>.jsonl <session>.jsonl.bak

# 3. Clear the inbox
rm -f $TELEGRAM_STATE_DIR/inbox/*

# 4. Restart the service
systemctl --user restart claude-<botname>.service
```

The new session starts clean. The bot's CLAUDE.md and memory files are unaffected.

Note: clearing the .jsonl removes the session from memory but NOT from disk (the .bak is there). Conversation history is gone; persona/memory survives.

### Screen injection doesn't work for interactive TUI

`screen -X stuff 'message\n'` injects text but can't navigate interactive menus (like `/resume`'s session picker or `claude auth login`'s OAuth prompt). For anything interactive, use `screen -r <session>` directly.

---

## Memory management

### Sessions grow to 3–4 GB after days

Claude Code keeps the full conversation context in memory. After a week of messages, a session can hit 3–4 GB RAM. Build a weekly restart into your cron or MemoryMax in the unit file:

```ini
[Service]
MemoryMax=2G
MemorySwapMax=256M
```

When memory is hit, systemd OOM-kills and restarts the service automatically.

### Weekly restart cron (recommended)

```bash
# ~/.config/cron/restart-bots (run via crontab -e)
0 4 * * 1 export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user restart claude-mybot.service
```

Pick 4AM Monday. Bots usually restart in <10 seconds.

---

## Systemd user services

### `loginctl enable-linger` is mandatory

Without linger, systemd user services stop when the user logs out:

```bash
sudo loginctl enable-linger homelab
```

Run this once per machine. Verify: `loginctl show-user homelab | grep Linger`

### XDG_RUNTIME_DIR must be set for remote commands

When SSHing to manage services remotely, always export this first:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user status claude-mybot.service
```

Without it: `Failed to connect to bus: No medium found`

### Service type should be `simple`, not `forking`

Even though `screen` forks, use `Type=simple`. Screen with `-D -m` flags behaves as a foreground process from systemd's perspective — `Type=forking` causes systemd to think the service failed immediately.

---

## Proxmox operations

### `pct exec` vs `pct enter`

- `pct exec <ID> -- command` — runs a command non-interactively. Good for scripts, bad for OAuth or anything that needs stdin.
- `pct enter <ID>` — gives you a real TTY inside the container. Use this for `claude auth login`.

### SSH key distribution

Add your SSH public key to `~homelab/.ssh/authorized_keys` on each LXC. Then you can SSH directly to LXC IPs without going through the Proxmox host:

```bash
ssh -i ~/.ssh/id_ed25519_homelab homelab@192.168.1.X
```

This is cleaner than proxying through the Proxmox node and doesn't require root on the hypervisor.

---

## Security

### Never give a bot unrestricted sudo

Claude Code with `--dangerously-skip-permissions` will use whatever tools it has. A `sudo rm -rf` is only a hallucination away. Use a sudoers allowlist:

```
# /etc/sudoers.d/homelab-bot
homelab ALL=(ALL) NOPASSWD: /usr/bin/docker, /bin/systemctl restart myservice
```

### Telegram allowlist is your perimeter

The `access.json` allowlist is the only thing stopping anyone who knows your bot token from sending it commands. Keep `dmPolicy: "allowlist"` and only add your own Telegram ID.

### Rotate tokens if a bot LXC is compromised

Each bot has its own Telegram token. If one LXC is compromised, revoke that token via @BotFather and issue a new one. The others are unaffected.

---

## Debugging

### Check what a running bot is doing

```bash
# Snapshot the current screen contents
screen -S mybot_bot -X hardcopy /tmp/dump.txt && cat /tmp/dump.txt

# Or stream the journal logs
journalctl --user -u claude-mybot.service -f
```

### Bot starts but doesn't respond to Telegram messages

Check in order:
1. Is the service actually running? `systemctl --user status claude-mybot.service`
2. Is the Telegram plugin installed? `claude plugins list` (from inside the LXC)
3. Is access.json correct? `cat $TELEGRAM_STATE_DIR/access.json`
4. Is the bot token valid? Test with `curl https://api.telegram.org/botTOKEN/getMe`
5. Did you install the marketplace before the plugin? (See above)

### Bot responds but ignores certain messages

The Telegram plugin has an allowlist. If a message comes from a chat_id not in `allowFrom`, it's silently dropped. Check the `access.json`.
