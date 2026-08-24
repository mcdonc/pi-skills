# pi Keybase extension

Connects pi to Keybase chat through the local `keybase chat api` JSON
API (requires the Keybase client installed, running, and logged in).

## Tools

| Tool | What it does |
|---|---|
| `keybase_status` | Report login, service, and conversation count |
| `keybase_list_conversations` | List DMs and team channels, newest first (`unread_only` filter) |
| `keybase_read` | Read recent messages from a channel (marks as read) |
| `keybase_send` | Send a message to a channel |

Channels: `"username"` for DMs (either party's name works), `"teamname"`
or `"teamname#topic"` with `team: true` for team channels.

## Commands

- `/keybase-status` — quick login/conversation summary

## Remote control ("grocery store mode")

Drives pi from the Keybase app on your phone. The extension watches
your self-DM via `keybase chat api-listen`; any message starting with
`pi ` becomes an agent prompt, and the agent's final answer is posted
back to the same chat with a 🤖 prefix. Ordinary chat and the bot's own
replies are ignored, so there's no loop.

On only in sessions launched with `KEYBASE_REMOTE=1` (e.g. a dedicated
herdr tab — see below). `/keybase-remote on|off` toggles any session
at runtime. Opt-in prevents several concurrent pi sessions from all
answering the same phone command. Configure via environment:

| Variable | Default | Meaning |
|---|---|---|
| `KEYBASE_REMOTE` | unset | Set `1` to enable listening (opt-in) |
| `KEYBASE_REMOTE_PREFIX` | `pi` | Command prefix (`pi <prompt>` or `pi:<prompt>`) |
| `KEYBASE_REMOTE_CHANNEL` | own username | Channel to watch (self-DM by default) |
| `KEYBASE_REMOTE_TEAM` | `0` | Set `1` when the watch channel is a team |

`/keybase-remote on|off` toggles the listener at runtime; bare
`/keybase-remote` shows status.

### Commands

- `pi <prompt>` — run a prompt in the listening session
- `pi on` — pi mode: every message becomes a prompt (no prefix needed);
  bot replies are ignored, so there's no loop. `pi off` exits
- `pi stop` — abort the in-flight remote turn (partial reply is finalized
  with a `⏹ (stopped)` marker; `pi abort`/`pi halt` are synonyms)
- `pi sessions` — list recent sessions, numbered
- `pi session <n|text>` — switch the listening pi to that session;
  afterwards `pi <prompt>` runs with that session's context. Numbered
  picks refer to the last `pi sessions` listing. Switching works by
  typing real keystrokes into the pane via the herdr socket (extension-sent
  messages are never command-intercepted by pi), so it requires the
  agent to run in a herdr pane
- `pi new` — drop the current context and start a fresh session
- `pi status` — show the active session and whether a turn is running
- `pi help` — list these commands

Example grocery-store flow: `pi sessions` → `pi session 3` →
`pi what were we doing, continue with step 3`.

### Streaming replies

Instead of waiting for the full answer, the agent's reply streams into a
**single** chat message: a placeholder appears when the turn starts (with a
`⏳ <tool>…` note while tools run), then the message is live-edited as text
streams, and a final edit replaces it with the settled answer (~2.5 s edit
throttle, replies capped at ~4000 chars). If message editing fails, the
partial is deleted and one plain message is sent instead. All writes go
through a serialized queue with generation checks, so a stale edit can
never land after the final message.

Set `KEYBASE_REMOTE_DEBUG=1` to log the remote-control lifecycle to
`/tmp/keybase-ext-debug.log` (useful when something misbehaves).

Notes:

- Only messages sent by the logged-in account are accepted as commands,
  and the self-DM is private to that account, so no one else can drive
  the agent.
- Replies are truncated to ~3500 characters.
- Long jobs: the ack (`🤖 got it`) is sent immediately; the answer
  arrives when the agent settles.

## Persistent agent in a herdr tab

Run the remote-controlled agent in a named herdr tab so it survives
detach and is always available:

```
herdr agent start keybase --cwd ~ -- env KEYBASE_REMOTE=1 pi
```

Then from anywhere: `herdr agent attach keybase` to watch it work,
`herdr agent read keybase --lines 50` to peek at its output,
`herdr agent wait keybase --status idle` to block until it finishes.
Phone commands (`pi <prompt>`) land in that session. Send `pi stop`
(also `pi abort` / `pi halt`) mid-run to abort the current remote turn;
whatever partial reply streamed is finalized with a `⏹ (stopped)` marker.
