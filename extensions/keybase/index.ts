/**
 * pi extension: Keybase chat integration.
 *
 * Wraps the local `keybase chat api` JSON API so the agent can list
 * conversations, read messages, and send replies in Keybase chat.
 * Requires the Keybase client installed and `keybased` running, logged
 * in as the current user.
 *
 * Remote control: watches your self-DM (or KEYBASE_REMOTE_CHANNEL) via
 * `keybase chat api-listen`. Messages starting with "pi " (or
 * KEYBASE_REMOTE_PREFIX) become agent prompts; the agent's final reply is
 * posted back to the channel with a 🤖 prefix. Disabled with
 * KEYBASE_REMOTE=0.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn, type ChildProcess } from "node:child_process";
import { createConnection } from "node:net";
import { appendFileSync, existsSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DEBUG_LOG = process.env.KEYBASE_REMOTE_DEBUG ? "/tmp/keybase-ext-debug.log" : null;
function debug(line: string) {
  if (DEBUG_LOG) appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${line}\n`);
}

const KEYBASE_TIMEOUT_MS = 30_000;

/** Spawn `keybase <args>`, ignore stdin, return stdout. Rejects on nonzero exit. */
function run(...args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn("keybase", args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`keybase ${args.join(" ")} timed out`));
    }, 10_000);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) reject(new Error(stderr.trim() || `exit code ${code}`));
      else resolve(stdout);
    });
  });
}

// ---------- Keybase JSON API helpers ----------

type ApiEnvelope = { result?: unknown; error?: { message?: string; code?: number } };

type Channel = {
  name: string; // "them" | "you,them" | "teamname" | "teamname,subteam"
  members_type?: string; // "team" | "impteamnative" | "impteamupgrade"
  topic_name?: string; // team channel, e.g. "general"
  topic_type?: string;
};

type Conv = {
  id: string;
  channel: Channel;
  unread: boolean;
  active_at_ms?: number;
};

type Msg = {
  id: number;
  channel: Channel;
  sender?: { username?: string };
  sent_at?: number;
  content?: { type?: string; text?: { body?: string } };
};

/** Run one `keybase chat api` call. Returns result.error as a thrown Error. */
async function api(method: string, options: Record<string, unknown> = {}): Promise<unknown> {
  const body = JSON.stringify({ method, params: { options } });
  return new Promise<unknown>((resolve, reject) => {
    const child = spawn("keybase", ["chat", "api"], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`keybase chat api timed out after ${KEYBASE_TIMEOUT_MS}ms`));
    }, KEYBASE_TIMEOUT_MS);
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(new Error(`failed to spawn keybase: ${err.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(
          new Error(
            `keybase chat api exited with code ${code} (is keybased running?): ${stderr.trim()}`
          )
        );
        return;
      }
      let env: ApiEnvelope;
      try {
        env = JSON.parse(stdout) as ApiEnvelope;
      } catch {
        reject(new Error(`keybase chat api returned non-JSON output: ${stdout.slice(0, 200)}`));
        return;
      }
      if (env.error) {
        reject(new Error(`Keybase API error: ${env.error.message ?? JSON.stringify(env.error)}`));
        return;
      }
      resolve(env.result);
    });
    child.stdin.on("error", () => {}); // EPIPE if keybase dies early
    child.stdin.end(body);
  });
}

function fmtConv(c: Conv): string {
  const name = c.channel.topic_name
    ? `${c.channel.name}#${c.channel.topic_name}`
    : c.channel.name;
  const kind = c.channel.members_type === "team" ? "team" : "dm";
  const when = c.active_at_ms ? new Date(c.active_at_ms).toISOString().slice(0, 16) : "?";
  return `${name} (${kind}, last ${when}${c.unread ? ", UNREAD" : ""})`;
}

function fmtMsg(m: Msg): string {
  const who = m.sender?.username ?? "?";
  const when = m.sent_at ? new Date(m.sent_at * 1000).toISOString().slice(0, 16) : "?";
  const kind = m.content?.type ?? "unknown";
  const body =
    m.content?.type === "text" ? (m.content?.text?.body ?? "") : `<non-text: ${kind}>`;
  return `[${when}] ${who}: ${body}`;
}

/** Build channel options for the API from tool params. */
function channelOptions(channel: string, team: boolean, topic?: string): Record<string, unknown> {
  const ch: Record<string, unknown> = {
    name: channel,
    ...(topic ? { topic_name: topic } : {}),
  };
  if (team) {
    ch.members_type = "team";
    ch.topic_type = "chat";
  }
  return ch;
}

// ---------- Extension ----------

export default function (pi: ExtensionAPI) {
  /** Resolve a channel argument that may be "team", "team#channel", or a DM name. */
  function parseChannel(channel: string, team: boolean) {
    let name = channel.trim();
    let topicName: string | undefined;
    const hash = name.indexOf("#");
    if (hash !== -1) {
      topicName = name.slice(hash + 1).trim() || undefined;
      name = name.slice(0, hash).trim();
    }
    return { channel: channelOptions(name, team, topicName) };
  }

  async function checkStatus(): Promise<string> {
    let who: string;
    try {
      const stdout = await run("status");
      const m = stdout.match(/Username:\s+(\S+)/);
      who = m ? m[1] : "unknown";
    } catch {
      return "keybase: client unavailable or service not running";
    }
    let convCount = 0;
    try {
      const result = (await api("list")) as { conversations?: Conv[] };
      convCount = result.conversations?.length ?? 0;
    } catch {
      return `keybase: logged in as ${who}, but chat API failed`;
    }
    return `keybase: logged in as ${who}, ${convCount} conversations`;
  }

  // ---- Tools ----

  pi.registerTool({
    name: "keybase_status",
    label: "Keybase Status",
    description:
      "Check whether the local Keybase client and chat API are available and report the logged-in username and conversation count.",
    parameters: Type.Object({}),
    async execute() {
      const text = await checkStatus();
      return { content: [{ type: "text", text }] };
    },
  });

  pi.registerTool({
    name: "keybase_list_conversations",
    label: "Keybase List Conversations",
    description:
      "List Keybase chat conversations (direct messages and teams) visible to the logged-in user, newest activity first.",
    parameters: Type.Object({
      unread_only: Type.Optional(
        Type.Boolean({ description: "Only show conversations with unread messages. Default false." })
      ),
    }),
    async execute(_id, params) {
      const result = (await api("list")) as { conversations?: Conv[] };
      let convs = result.conversations ?? [];
      convs.sort((a, b) => (b.active_at_ms ?? 0) - (a.active_at_ms ?? 0));
      if (params.unread_only) convs = convs.filter((c) => c.unread);
      if (convs.length === 0) {
        return { content: [{ type: "text", text: "No conversations found." }] };
      }
      const text = convs.map(fmtConv).join("\n");
      return { content: [{ type: "text", text }] };
    },
  });

  pi.registerTool({
    name: "keybase_read",
    label: "Keybase Read Messages",
    description:
      'Read recent messages from a Keybase chat conversation. For a team channel use e.g. "myteam#general" with team=true (topic defaults to "general"); for a direct message use the other user\'s name, e.g. "alice". Marks the conversation as read.',
    parameters: Type.Object({
      channel: Type.String({
        description:
          'Conversation: "username" for DMs (either party), "teamname" or "teamname#topic" for teams.',
      }),
      team: Type.Optional(
        Type.Boolean({ description: "Treat the channel as a team. Default false." })
      ),
      count: Type.Optional(
        Type.Number({ description: "Number of messages to fetch. Default 10, max 100." })
      ),
    }),
    async execute(_id, params) {
      const num = Math.min(Math.max(Math.floor(params.count ?? 10), 1), 100);
      const result = (await api("read", {
        ...parseChannel(params.channel, params.team ?? false),
        pagination: { num },
      })) as { messages?: { msg?: Msg }[] };
      const msgs = (result.messages ?? []).map((m) => m.msg).filter((m): m is Msg => !!m);
      if (msgs.length === 0) {
        return { content: [{ type: "text", text: "No messages found in that conversation." }] };
      }
      // API returns newest-first with pagination; present oldest-first for readability
      const text = msgs.map(fmtMsg).reverse().join("\n");
      return { content: [{ type: "text", text }] };
    },
  });

  pi.registerTool({
    name: "keybase_send",
    label: "Keybase Send Message",
    description:
      'Send a message to a Keybase chat conversation. For a team channel use e.g. "myteam#general" with team=true; for a direct message use the other user\'s name, e.g. "alice". Messages are sent as the logged-in user.',
    parameters: Type.Object({
      channel: Type.String({
        description: 'Conversation: "username" for DMs, "teamname" or "teamname#topic" for teams.',
      }),
      message: Type.String({ description: "Message body to send." }),
      team: Type.Optional(
        Type.Boolean({ description: "Treat the channel as a team. Default false." })
      ),
    }),
    async execute(_id, params) {
      await api("send", {
        ...parseChannel(params.channel, params.team ?? false),
        message: { body: params.message },
      });
      return {
        content: [{ type: "text", text: `Sent to ${params.channel}.` }],
      };
    },
  });

  // ---- Commands ----

  pi.registerCommand("keybase-status", {
    description: "Show Keybase login status and conversation count",
    handler: async (_args, ctx) => {
      ctx.ui.notify(await checkStatus(), "info");
    },
  });

  // ---- Remote control (drive pi from Keybase chat) ----

  // Single-listener lock: at most one pi session may watch a channel.
  // Prevents two concurrent sessions (e.g. extra herdr tabs) from both
  // answering the same phone command.
  function procStartTicks(pid: number): string | null {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      // field 22 (1-indexed) after the parenthesized comm; comm may contain
      // spaces, so parse after the last ')'
      const rest = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      return rest[19] ?? null; // starttime in clock ticks
    } catch {
      return null;
    }
  }

  function lockPathFor(channelName: string): string {
    const safe = channelName.replace(/[^a-zA-Z0-9_.-]/g, "_");
    return join(tmpdir(), `keybase-pi-remote-${safe}.lock`);
  }

  function acquireLock(path: string): boolean {
    const mine = `${process.pid}:${procStartTicks(process.pid) ?? "?"}`;
    try {
      if (existsSync(path)) {
        const [pidStr, start] = readFileSync(path, "utf8").trim().split(":");
        const pid = Number(pidStr);
        const alive = Number.isFinite(pid) && pid > 0 && procStartTicks(pid) !== null;
        const sameStart = alive && procStartTicks(pid) === start;
        if (alive && (!start || sameStart)) {
          return false; // a live holder owns the channel
        }
        // stale lock: holder process is gone, take over
      }
      writeFileSync(path, mine);
      return true;
    } catch {
      return false;
    }
  }

  function releaseLock(path: string) {
    try {
      if (existsSync(path)) {
        const [pidStr] = readFileSync(path, "utf8").trim().split(":");
        if (Number(pidStr) === process.pid) unlinkSync(path);
      }
    } catch {
      // ignore
    }
  }

  const REMOTE_PREFIX = process.env.KEYBASE_REMOTE_PREFIX ?? "pi";
  // Opt-in: only sessions launched with KEYBASE_REMOTE=1 listen. Prevents
  // multiple concurrent pi sessions (herdr tabs, worktrees) from all
  // answering the same phone command. /keybase-remote on still works
  // as a per-session manual override.
  const remoteEnabled = () => process.env.KEYBASE_REMOTE === "1";
  const remoteOn = { current: false }; // toggled by /keybase-remote

  type Remote = {
    me: string;
    watch: Record<string, unknown>; // channel options for filter + replies
    child: ChildProcess | null;
    seen: Set<number>;
    seenQueue: number[];
    active: boolean; // a remote-triggered turn is in flight
    lastAssistant: string | null;
    restartTimer: NodeJS.Timeout | null;
    stopped: boolean;
    restarts: number;
    lockPath: string | null;
    // streaming state (live-edit one message instead of sending many)
    streamMsgId: number | null;
    turnText: string; // all assistant messages this remote turn, accumulated
    streamText: string;
    toolLog: string[]; // one line per tool call this turn, in order
    lastSentBody: string;
    lastEditAt: number;
    editTimer: NodeJS.Timeout | null;
    streamFailed: boolean;
    gen: number; // bumped each reset; stale async work self-aborts
    awaitingTurn: boolean; // command queued, its agent turn not started yet
    pendingSums: Map<string, string>; // toolCallId -> input summary line
    stoppedByUser: boolean; // "pi stop" received for the active turn
    sessionSlots: string[]; // paths from the last "pi sessions" listing
    dirSlots: string[]; // dirs from the last "pi dirs" listing
    piMode: boolean; // when on, every (non-bot) message is a prompt
    selfSent: Set<number>; // message ids we sent ourselves (loop guard)
  };
  let remote: Remote | null = null;
  // Latest ExtensionContext, so the listener (which runs outside event
  // handlers) can call ctx.abort() for "pi stop".
  let ctxRef: ExtensionContext | null = null;

  const EDIT_INTERVAL_MS = 2_500;
  const STREAM_MAX_CHARS = 4_000;

  function markSeen(r: Remote, id: number) {
    if (r.seen.has(id)) return false;
    r.seen.add(id);
    r.seenQueue.push(id);
    while (r.seenQueue.length > 500) {
      const old = r.seenQueue.shift();
      if (old !== undefined) r.seen.delete(old);
    }
    return true;
  }

  async function sendTo(r: Remote, body: string): Promise<void> {
    try {
      const res = (await api("send", { channel: r.watch, message: { body } })) as {
        id?: number;
      };
      if (res.id !== undefined) {
        r.selfSent.add(res.id);
        if (r.selfSent.size > 1000) {
          const drop = [...r.selfSent].slice(0, r.selfSent.size - 500);
          for (const id of drop) r.selfSent.delete(id);
        }
      }
    } catch (err) {
      debug(`send-err: ${String(err)}`);
    }
  }

  function resetStream(r: Remote) {
    r.gen += 1; // invalidate any in-flight send/edit for the old turn
    if (r.editTimer) clearTimeout(r.editTimer);
    r.editTimer = null;
    r.streamMsgId = null;
    r.turnText = "";
    r.streamText = "";
    r.toolLog = [];
    r.pendingSums.clear();
    r.lastSentBody = "";
    r.lastEditAt = 0;
    r.streamFailed = false;
  }

  function textOf(message: { content?: Array<{ type: string; text?: string }> }): string {
    return (message.content ?? [])
      .filter((p) => p.type === "text")
      .map((p) => p.text ?? "")
      .join("")
      .trim();
  }

  function streamBody(r: Remote): string {
    // Full turn output = completed messages + current streaming partial.
    // A turn is one logical answer made of many assistant messages (one per
    // tool round); replacing instead of accumulating wiped earlier text.
    let body = r.turnText + r.streamText;
    const log = r.toolLog.join("\n");
    if (!body.trim()) body = log || "…";
    else if (log) body += `\n\n${log}`;
    if (body.length > STREAM_MAX_CHARS) {
      // keep head and tail: earlier findings + the newest output
      const head = Math.floor(STREAM_MAX_CHARS * 0.35);
      const tail = STREAM_MAX_CHARS - head;
      body = `${body.slice(0, head)}\n… (middle truncated) …\n${body.slice(-tail)}`;
    }
    return `🤖 ${body}`;
  }

  /**
   * All Keybase writes triggered by streaming/settle go through this serial
   * queue. Each task carries the generation it was created under; a bump
   * (resetStream / settle) drops every older task, so a stale placeholder or
   * edit can never land after the final message.
   */
  let writeQueue: Promise<void> = Promise.resolve();
  function enqueueWrite(r: Remote, fn: () => Promise<void>) {
    const gen = r.gen;
    writeQueue = writeQueue
      .then(async () => {
        if (r.gen !== gen || r.stopped) return; // stale or shut down
        await fn();
      })
      .catch(() => {});
  }

  async function doStreamEdit(r: Remote) {
    const gen = r.gen;
    if (!r.streamMsgId) {
      try {
        const res = (await api("send", {
          channel: r.watch,
          message: { body: streamBody(r) },
        })) as { id?: number };
        if (r.gen !== gen) {
          // turn settled while the placeholder was in flight: remove it
          if (res.id !== undefined) {
            api("delete", { channel: r.watch, message_id: res.id }).catch(() => {});
          }
          return;
        }
        r.streamMsgId = res.id ?? null;
        r.lastSentBody = streamBody(r);
        debug(`placeholder sent id=${r.streamMsgId}`);
      } catch (err) {
        debug(`placeholder-send-err: ${String(err)}`);
        // could not create placeholder; final send on settle will still fire
      }
      return;
    }
    const body = streamBody(r);
    if (body === r.lastSentBody) return;
    try {
      await api("edit", {
        channel: r.watch,
        message_id: r.streamMsgId,
        message: { body },
      });
      r.lastSentBody = body;
      r.lastEditAt = Date.now();
      debug(`edit ok id=${r.streamMsgId} len=${body.length}`);
    } catch (err) {
      debug(`edit-err id=${r.streamMsgId}: ${String(err)}`);
      // edit rejected (deleted, too old, ...): drop the stale partial and
      // fall back to a single plain send when the agent settles
      const deadId = r.streamMsgId;
      r.streamMsgId = null;
      r.streamFailed = true;
      if (deadId !== null) {
        api("delete", { channel: r.watch, message_id: deadId }).catch((e) =>
          debug(`delete-err id=${deadId}: ${String(e)}`)
        );
      }
    }
  }

  /** Throttled live edit of the streaming message. */
  function scheduleStreamEdit(r: Remote, immediate = false) {
    if (r.streamFailed) return; // editing broken this turn; plain send at settle
    if (r.editTimer) return;
    const wait = immediate || Date.now() - r.lastEditAt >= EDIT_INTERVAL_MS
      ? 0
      : EDIT_INTERVAL_MS - (Date.now() - r.lastEditAt);
    r.editTimer = setTimeout(() => {
      r.editTimer = null;
      if (!r.active) return; // turn already settled; the final write wins
      enqueueWrite(r, () => doStreamEdit(r));
    }, wait);
    r.editTimer.unref?.();
  }

  // Inside herdr: type into our own pane via the herdr socket. Real
  // interactive input gets command-intercepted (extension-sent messages
  // never do — pi sends them with expandPromptTemplates: false).
  function herdrPaneId(): string | null {
    if (process.env.HERDR_ENV !== "1") return null;
    const sock = process.env.HERDR_SOCKET_PATH;
    const pane = process.env.HERDR_PANE_ID;
    return sock && pane ? pane : null;
  }

  function herdrRequest(method: string, params: Record<string, unknown>): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = createConnection(process.env.HERDR_SOCKET_PATH!);
      let settled = false;
      const finish = (err?: Error) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        err ? reject(err) : resolve();
      };
      socket.on("error", (err) => finish(err));
      socket.on("connect", () =>
        socket.write(`${JSON.stringify({ id: `kb:${Date.now()}`, method, params })}\n`)
      );
      let buf = "";
      socket.on("data", (d) => {
        buf += d;
        if (buf.includes("\n")) {
          try {
            const resp = JSON.parse(buf.slice(0, buf.indexOf("\n")));
            if (resp.error) finish(new Error(resp.error.message ?? "herdr error"));
            else finish();
          } catch {
            finish();
          }
        }
      });
      setTimeout(() => finish(new Error("herdr socket timeout")), 5000).unref?.();
    });
  }

  /** Type a slash command into our own herdr pane and submit it. */
  async function typeCommand(command: string): Promise<boolean> {
    const pane = herdrPaneId();
    if (!pane) return false;
    await herdrRequest("pane.send_input", { pane_id: pane, text: command });
    await herdrRequest("pane.send_keys", { pane_id: pane, keys: ["enter"] });
    return true;
  }

  async function handleListenLine(r: Remote, line: string, pi2: ExtensionAPI) {
    let obj: { type?: string; source?: string; msg?: Msg };
    try {
      obj = JSON.parse(line) as typeof obj;
    } catch {
      return;
    }
    debug(`listen-line type=${obj.type} source=${obj.source ?? ""} id=${obj.msg?.id}`);
    if (obj.type !== "chat" || !obj.msg) return;
    const m = obj.msg;
    if (!markSeen(r, m.id)) return; // remote + local echoes share an id
    if (r.selfSent.has(m.id)) return; // our own bot message echoed back
    // Only commands from the account owner (self-DM is private anyway).
    if (m.sender?.username !== r.me) return;
    if (m.content?.type !== "text") return;
    const body = m.content.text?.body ?? "";
    const re = new RegExp(`^${REMOTE_PREFIX}[:\\s]\\s*`, "i");
    const prefixed = re.test(body);
    // In pi mode every message is a prompt; our own 🤖 replies and
    // already-prefixed control commands are exempt.
    if (!prefixed && !(r.piMode && !body.startsWith("🤖"))) {
      return; // ordinary chat passes through
    }
    const command = prefixed ? body.replace(re, "").trim() : body;
    if (!command) return;
    // "pi dirs" — list known project directories (no agent turn needed)
    if (/^dirs?$/i.test(command)) {
      const home = process.env.HOME ?? "/home/chrism";
      try {
        const sessions = await SessionManager.listAll();
        const latest = new Map<string, number>();
        for (const s of sessions) {
          const ts = Number(new Date(s.modified));
          latest.set(s.cwd, Math.max(latest.get(s.cwd) ?? 0, ts));
        }
        const dirs = [...latest.entries()].sort((a, b) => b[1] - a[1]).map(([d]) => d);
        for (const d of (process.env.KEYBASE_REMOTE_DIRS ?? "").split(":")) {
          if (d && !dirs.includes(d)) dirs.push(d);
        }
        if (!dirs.includes(home)) dirs.push(home);
        r.dirSlots = dirs;
        const lines = dirs.slice(0, 15).map((d, i) => {
          const shown = (d === home ? "~" : d.replace(home, "~")).replace(/\/{2,}/g, "/");
          return `${i + 1}. ${shown}`;
        });
        await sendTo(
          r,
          `🤖 directories ("pi cd <n|path>"):\n${lines.join("\n")}`
        );
      } catch (err) {
        await sendTo(r, `🤖 dir list failed: ${String(err)}`);
      }
      return;
    }
    // "pi cd <n|path>" — change working directory (jumps to that project's
    // latest session, or a fresh one if none exists there)
    const cdMatch = command.match(/^cd\s+(.+)$/i);
    if (cdMatch) {
      const home = process.env.HOME ?? "/home/chrism";
      const t = cdMatch[1].trim();
      const slot = Number(t);
      let dir: string | null = null;
      if (/^\d+$/.test(t)) {
        if (r.dirSlots.length === 0) {
          await sendTo(r, '🤖 no directory list yet — send "pi dirs" first');
          return;
        }
        if (!(slot >= 1 && slot <= r.dirSlots.length)) {
          await sendTo(r, `🤖 no dir ${slot} — list has ${r.dirSlots.length}`);
          return;
        }
        dir = r.dirSlots[slot - 1];
      } else {
        dir = t.replace(/^~(?=\/|$)/, home);
      }
      await sendTo(r, `🤖 cd ${dir === home ? "~" : dir.replace(home, "~/")}…`);
      if (!(await typeCommand(`/keybase-cd ${dir}`))) {
        await sendTo(r, "🤖 cd needs a herdr pane");
      }
      return;
    }
    // "pi on"/"pi off" — toggle pi mode (every message becomes a prompt)
    if (/^(on|mode)$/i.test(command)) {
      r.piMode = true;
      debug("pi mode on");
      pi2.appendEntry("keybase-remote-state", { piMode: true });
      await sendTo(
        r,
        "🤖 pi mode ON — every message is a prompt. \"pi off\" exits."
      );
      return;
    }
    if (/^off$/i.test(command)) {
      r.piMode = false;
      debug("pi mode off");
      pi2.appendEntry("keybase-remote-state", { piMode: false });
      await sendTo(r, "🤖 pi mode OFF — prefix commands with \"pi \" again.");
      return;
    }
    // "pi help" — command card
    if (/^(help|\?)\.?$/i.test(command)) {
      await sendTo(
        r,
        [
          "🤖 pi remote commands:",
          "pi <prompt> — run a prompt here",
          "pi on — pi mode: every message is a prompt",
          "pi off — exit pi mode",
          "pi stop — abort the running turn",
          "pi sessions — list recent sessions",
          "pi session <n|text> — switch session",
          "pi dirs — list project directories",
          "pi cd <n|path> — change directory",
          "pi new — start a fresh session",
          "pi status — what am I doing now",
        ].join("\n")
      );
      return;
    }
    /** Run a short shell command in dir; empty string on failure. */
  async function exec(cwd: string, script: string): Promise<string> {
    return new Promise((resolve) => {
      const child = spawn("bash", ["-c", script], {
        cwd,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let out = "";
      const timer = setTimeout(() => {
        child.kill();
        resolve("");
      }, 5000);
      child.stdout.on("data", (d) => (out += d));
      child.on("error", () => {
        clearTimeout(timer);
        resolve("");
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        resolve(code === 0 ? out.trim() : "");
      });
    });
  }

  // "pi status" — active session + run state, no agent turn needed
    if (/^status$/i.test(command)) {
      let title = "(new session)";
      try {
        const sm = ctxRef?.sessionManager;
        const name = sm?.getSessionName();
        if (name) {
          title = name;
        } else {
          const firstUser = sm
            ?.getEntries()
            .find((e) => e.type === "message" && e.message.role === "user");
          const text =
            firstUser && firstUser.type === "message"
              ? firstUser.message.content.find((p) => p.type === "text")?.text
              : undefined;
          if (text) title = text.slice(0, 45).replace(/\s+/g, " ");
        }
      } catch {
        // fall back to (new session)
      }
      // git worktree/branch line (only when the cwd is a repo)
      let gitLine = "";
      try {
        const cwd = ctxRef?.sessionManager.getCwd();
        if (cwd) {
          const out = await exec(
            cwd,
            "git rev-parse --abbrev-ref HEAD 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null"
          );
          if (out) {
            const [branch, root] = out.split("\n").filter(Boolean);
            const shownRoot = root.replace(process.env.HOME ?? "", "~");
            gitLine =
              shownRoot === cwd.replace(process.env.HOME ?? "", "~")
                ? `\n🌿 ${branch}`
                : `\n🌿 ${branch} · ${cwd.replace(process.env.HOME ?? "", "~").replace(shownRoot + "/", "")}`;
          }
        }
      } catch {
        // not a repo — no git line
      }
      await sendTo(
        r,
        `🤖 session: ${title}${r.piMode ? " · pi mode ON" : ""}\n📁 ${ctxRef?.sessionManager.getCwd().replace(process.env.HOME ?? "", "~")}${gitLine}${r.active ? "\n⏳ a turn is running" : "\n💤 idle"}`
      );
      return;
    }
    // "pi sessions" — list saved sessions (no agent turn needed)
    if (/^sessions?$/i.test(command)) {
      try {
        const sessions = await SessionManager.listAll();
        sessions.sort((a, b) => Number(new Date(b.modified)) - Number(new Date(a.modified)));
        const lines = sessions
          .filter((s) => s.messageCount > 0)
          .slice(0, 15)
          .map((s, i) => {
            const title = (s.firstMessage ?? "(unnamed)").slice(0, 45).replace(/\s+/g, " ");
            const proj = s.cwd.replace("/home/chrism/", "~/").split("/").pop();
            return `${i + 1}. ${title} · ${proj}`;
          });
        r.sessionSlots = sessions
          .filter((s) => s.messageCount > 0)
          .slice(0, 15)
          .map((s) => s.path);
        await sendTo(
          r,
          lines.length
            ? `🤖 recent sessions ("pi session <n>"):\n${lines.join("\n")}`
            : "🤖 no saved sessions found"
        );
      } catch (err) {
        await sendTo(r, `🤖 session list failed: ${String(err)}`);
      }
      return;
    }
    // "pi session <n|id|text>" — switch this pi to another session.
    // A plain number refers to the last "pi sessions" listing (phone-friendly).
    const sessionMatch = command.match(/^session\s+(.+)$/i);
    if (sessionMatch) {
      const target = sessionMatch[1].trim();
      const slot = Number(target);
      if (Number.isInteger(slot) && slot >= 1 && slot <= (r.sessionSlots.length || 0)) {
        const path = r.sessionSlots[slot - 1];
        const file = path.split("/").pop() ?? path;
        await sendTo(r, `🤖 switching to session ${slot}…`);
        debug(`session switch by slot ${slot}: ${file}`);
        if (!(await typeCommand(`/keybase-session-path ${path}`))) {
          await sendTo(r, "🤖 session switching needs a herdr pane");
        }
        return;
      }
      await sendTo(r, `🤖 switching to: ${target.slice(0, 60)}`);
      debug(`session switch requested: ${target}`);
      if (!(await typeCommand(`/keybase-session ${target}`))) {
        await sendTo(r, "🤖 session switching needs a herdr pane");
      }
      return;
    }
    // "pi new" — start a fresh session
    if (/^new$/i.test(command)) {
      await sendTo(r, "🤖 starting a new session");
      if (!(await typeCommand("/keybase-new"))) {
        await sendTo(r, "🤖 session switching needs a herdr pane");
      }
      return;
    }
    // "pi stop" aborts the in-flight remote turn instead of prompting
    if (/^(stop|abort|halt)\.?$/i.test(command)) {
      if (!r.active && !r.awaitingTurn) {
        await sendTo(r, "🤖 nothing is running");
        return;
      }
      r.stoppedByUser = true;
      debug("stop requested by user");
      ctxRef?.abort();
      return;
    }
    await sendTo(r, `🤖 got it: ${command.slice(0, 80)}`);
    debug(`command accepted: ${command.slice(0, 60)}`);
    r.active = true;
    resetStream(r);
    r.awaitingTurn = true;
    pi2.sendUserMessage(command, { deliverAs: "followUp" });
  }

  /**
   * Start (or restart) the api-listen child. `first` acquires the lock;
   * restarts reuse it. The restart budget is NOT reset here — a listener
   * that keeps dying must eventually give up.
   */
  async function startListener(pi2: ExtensionAPI): Promise<void> {
    if (!remote) return;
    const r = remote;
    if (r.child) return;
    r.stopped = false;
    const stdout = await run("status");
    const userMatch = stdout.match(/Username:\s+(\S+)/);
    if (!userMatch) throw new Error("could not resolve Keybase username");
    r.me = userMatch[1];

    const channelArg = process.env.KEYBASE_REMOTE_CHANNEL ?? r.me;
    const team = process.env.KEYBASE_REMOTE_TEAM === "1";
    const parsed = parseChannel(channelArg, team);
    r.watch = parsed.channel as Record<string, unknown>;

    const lockPath = r.lockPath ?? lockPathFor(String(r.watch.name));
    if (!r.lockPath) {
      if (!acquireLock(lockPath)) {
        throw new Error(
          `another pi session is already listening on ${String(r.watch.name)} (${lockPath})`
        );
      }
      r.lockPath = lockPath;
    }

    const child = spawn(
      "keybase",
      ["chat", "api-listen", "--local", "--filter-channel", JSON.stringify(r.watch)],
      { stdio: ["ignore", "pipe", "pipe"] }
    );
    r.child = child;
    let buf = "";
    child.stdout.on("data", (d) => {
      buf += d;
      let nl: number;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim()) {
          handleListenLine(r, line, pi2).catch((err) =>
            debug(`listen handler error: ${String(err)}`)
          );
        }
      }
    });
    // keybase's stderr here is startup chatter (filter lists, config dumps)
    // plus real errors on abnormal exit; route it to the debug log only.
    child.stderr.on("data", (d) => debug(`listener-stderr: ${d.toString().trim()}`));
    child.on("error", (err) => debug(`listener spawn failed: ${err.message}`));
    child.on("close", () => {
      if (r.child === child) r.child = null;
      if (r.stopped || r.restarts >= 5) return;
      r.restarts++;
      r.restartTimer = setTimeout(() => {
        r.restartTimer = null;
        startListener(pi2).catch((err) => debug(`restart failed: ${String(err)}`));
      }, 15_000);
    });
  }

  function stopListener() {
    if (!remote) return;
    remote.stopped = true;
    if (remote.restartTimer) clearTimeout(remote.restartTimer);
    remote.restartTimer = null;
    remote.child?.kill();
    remote.child = null;
    if (remote.lockPath) {
      releaseLock(remote.lockPath);
      remote.lockPath = null;
    }
  }

  pi.on("session_start", async (event, ctx) => {
    ctxRef = ctx;
    if (!remoteEnabled()) return;
    if (ctx.mode !== "tui" && ctx.mode !== "rpc") return;
    if (!remote) remote = { me: "", watch: {}, child: null, seen: new Set(), seenQueue: [], active: false, lastAssistant: null, restartTimer: null, stopped: false, restarts: 0, lockPath: null, streamMsgId: null, turnText: "", streamText: "", toolLog: [], lastSentBody: "", lastEditAt: 0, editTimer: null, streamFailed: false, gen: 0, awaitingTurn: false, stoppedByUser: false, sessionSlots: [], dirSlots: [], pendingSums: new Map(), piMode: false, selfSent: new Set() };
    // restore pi mode from the session's persisted extension state
    try {
      const entries = ctx.sessionManager.getEntries();
      for (let i = entries.length - 1; i >= 0; i--) {
        const e = entries[i];
        if (e.type === "custom" && e.customType === "keybase-remote-state") {
          remote.piMode = !!(e.data as { piMode?: boolean } | undefined)?.piMode;
          break;
        }
      }
    } catch {
      // ignore
    }
    remoteOn.current = true;
    try {
      await startListener(pi);
      ctx.ui.notify(
        `Keybase remote control: listening, say "${REMOTE_PREFIX} <prompt>" in chat`, "info"
      );
      // Confirm (re)connection on the phone — but not on hot /reload
      if (event.reason !== "reload") {
        const home = process.env.HOME ?? "";
        const cwd = ctx.sessionManager.getCwd().replace(home, "~");
        await sendTo(
          remote,
          `🤖 online · ${cwd}${remote.piMode ? " · pi mode ON" : ""}`
        );
      }
    } catch (err) {
      ctx.ui.notify(`Keybase remote control not started: ${String(err)}`, "error");
    }
  });

  pi.on("session_shutdown", () => stopListener());

  pi.on("message_end", async (event) => {
    const r = remote;
    if (event.message.role !== "assistant" || !r) return;
    const text = textOf(event.message);
    if (r.active) {
      // commit the finished message to the turn's accumulated text and
      // clear the partial so the next message starts clean
      if (text) r.turnText += `${text}\n\n`;
      r.streamText = "";
    }
    r.lastAssistant = r.turnText || text || null;
  });

  pi.on("message_update", async (event) => {
    const r = remote;
    if (!r?.active || event.message.role !== "assistant") return;
    const text = textOf(event.message);
    if (!text) return;
    r.streamText = text;
    scheduleStreamEdit(r);
  });

  /** Short one-line summary of a tool call for the phone. */
  function toolSummary(name: string, input: unknown): string {
    const i = (input ?? {}) as Record<string, unknown>;
    const clip = (s: unknown, n = 40) =>
      String(s ?? "").replace(/\s+/g, " ").trim().slice(0, n);
    if (typeof i.command === "string") return clip(i.command, 60);
    if (typeof i.path === "string") return clip(i.path, 60);
    if (typeof i.channel === "string") return clip(i.channel, 30);
    if (typeof i.query === "string" || typeof i.queries === "object") {
      const q = i.query ?? (Array.isArray(i.queries) ? i.queries[0] : "");
      return clip(q, 60);
    }
    if (typeof i.url === "string") return clip(i.url, 60);
    if (typeof i.pattern === "string") return clip(i.pattern, 50);
    if (typeof i.name === "string") return clip(i.name, 30);
    const firstVal = Object.values(i)[0];
    return firstVal !== undefined ? clip(firstVal, 40) : "";
  }

  pi.on("tool_execution_start", async (event) => {
    const r = remote;
    if (!r?.active) return;
    const sum = toolSummary(event.toolName, event.args);
    const pending = sum ? `⏳ ${event.toolName} ${sum}` : `⏳ ${event.toolName}…`;
    r.pendingSums.set(event.toolCallId, sum);
    r.toolLog.push(pending);
    if (r.toolLog.length > 20) r.toolLog.shift();
    scheduleStreamEdit(r);
  });

  pi.on("tool_execution_end", async (event) => {
    const r = remote;
    if (!r?.active) return;
    // summarize the finished tool into the running transcript line
    let outcome = "";
    const parts = event.result?.content;
    if (Array.isArray(parts)) {
      const text = parts
        .filter((p: { type?: string }) => p.type === "text")
        .map((p: { text?: string }) => p.text ?? "")
        .join(" ")
        .replace(/\s+/g, " ")
        .trim();
      if (text) outcome = text.slice(0, 80);
    }
    // event.args is not populated here; reuse the summary captured at start
    const sum = r.pendingSums.get(event.toolCallId) ?? "";
    r.pendingSums.delete(event.toolCallId);
    const line = sum ? `${event.toolName} ${sum}` : event.toolName;
    // keep the result preview short so the input summary stays visible
    const preview = outcome ? ` → ${outcome.slice(0, 60)}` : "";
    const done = event.isError
      ? `❌ ${line}: ${outcome || "failed"}`
      : `✅ ${line}${preview}`;
    // replace this tool's pending "⏳" line, keeping earlier lines
    const pendingText = sum ? `⏳ ${event.toolName} ${sum}` : `⏳ ${event.toolName}…`;
    const pendingIdx = r.toolLog.indexOf(pendingText);
    if (pendingIdx !== -1) {
      r.toolLog[pendingIdx] = done;
    } else {
      const anyPending = r.toolLog.findIndex((l) => l.startsWith("⏳"));
      if (anyPending >= 0) r.toolLog[anyPending] = done;
      else {
        r.toolLog.push(done);
        if (r.toolLog.length > 20) r.toolLog.shift();
      }
    }
    scheduleStreamEdit(r);
  });

  pi.on("agent_start", (_event, ctx) => {
    ctxRef = ctx;
    const r = remote;
    if (r?.active && r.awaitingTurn) {
      r.awaitingTurn = false;
      debug("agent turn started");
    }
  });

  pi.on("agent_settled", async () => {
    const r = remote;
    if (!r?.active) return;
    if (r.awaitingTurn) {
      // settle fired before the queued turn started (spurious/pre-queue);
      // the real turn is still coming
      debug("ignoring premature settle (turn not started)");
      return;
    }
    r.active = false;
    // Invalidate all pending/older streaming writes SYNCHRONOUSLY, before
    // any await, so nothing stale can interleave with the final message.
    r.gen += 1;
    if (r.editTimer) {
      clearTimeout(r.editTimer);
      r.editTimer = null;
    }
    const streamMsgId = r.streamMsgId;
    const streamFailed = r.streamFailed;
    const stopped = r.stoppedByUser;
    const toolLog = [...r.toolLog]; // keep tool summaries in the final message
    let reply = (r.turnText || r.lastAssistant || "(no output)").trim();
    if (stopped) reply = reply ? `${reply}\n\n⏹ (stopped)` : "⏹ (stopped)";
    if (toolLog.length) reply += `\n\n${toolLog.join("\n")}`;
    r.stoppedByUser = false;
    r.streamMsgId = null;
    r.turnText = "";
    r.streamText = "";
    r.toolLog = [];
    r.lastSentBody = "";
    r.streamFailed = false;
    debug(`settled: streamMsgId=${streamMsgId} streamFailed=${streamFailed}`);
    enqueueWrite(r, async () => {
      // a stale placeholder task may have landed after the settle snapshot;
      // remove it so the chat shows exactly one message
      if (r.streamMsgId !== null && r.streamMsgId !== streamMsgId) {
        const leaked = r.streamMsgId;
        r.streamMsgId = null;
        await api("delete", { channel: r.watch, message_id: leaked }).catch(() => {});
      }
      const finalBody = `🤖 ${
        reply.length > STREAM_MAX_CHARS
          ? (() => {
              const head = Math.floor(STREAM_MAX_CHARS * 0.35);
              const tail = STREAM_MAX_CHARS - head;
              return `${reply.slice(0, head)}\n… (middle truncated) …\n${reply.slice(-tail)}`;
            })()
          : reply
      }`;
      if (streamMsgId !== null && !streamFailed) {
        try {
          await api("edit", {
            channel: r.watch,
            message_id: streamMsgId,
            message: { body: finalBody },
          });
          debug(`final edit ok id=${streamMsgId}`);
          return;
        } catch (err) {
          debug(`settled-edit-err id=${streamMsgId}: ${String(err)}`);
        }
      }
      await sendTo(r, finalBody);
      debug("final send ok");
    });
    r.lastAssistant = null;
  });

  // Session switching for remote control: "pi session <id|text>" queues
  // /keybase-session as a follow-up; commands run with ExtensionCommandContext,
  // which can switch sessions (event handlers cannot).
  pi.registerCommand("keybase-session", {
    description: "Switch this pi to another session by id prefix or text match",
    handler: async (args, ctx) => {
      const arg = args.trim();
      if (!arg) {
        ctx.ui.notify("usage: /keybase-session <id-prefix|text>", "info");
        return;
      }
      const sessions = await SessionManager.listAll();
      sessions.sort((a, b) => Number(new Date(b.modified)) - Number(new Date(a.modified)));
      const lower = arg.toLowerCase();
      const byId = sessions.filter((s) => s.id.toLowerCase().startsWith(lower));
      let hit;
      if (byId.length === 1) {
        hit = byId[0];
      } else if (byId.length > 1) {
        ctx.ui.notify(`ambiguous id prefix, ${byId.length} matches`, "error");
        return;
      } else {
        hit =
          sessions.find((s) => (s.firstMessage ?? "").toLowerCase().includes(lower)) ??
          sessions.find((s) => s.cwd.toLowerCase().includes(lower));
      }
      if (!hit) {
        ctx.ui.notify(`no session matches "${arg}"`, "error");
        return;
      }
      await ctx.waitForIdle();
      ctx.ui.notify(`Switching to [${hit.id.slice(0, 8)}] ${hit.firstMessage ?? hit.id}`, "info");
      await ctx.switchSession(hit.path, {
        withSession: async (ctx2) => {
          ctx2.ui.notify(
            `Remote session now: ${hit.firstMessage?.slice(0, 60) ?? hit.id}`,
            "info"
          );
        },
      });
    },
  });

  pi.registerCommand("keybase-cd", {
    description: "Change working directory: switch to that project's latest session (or a new one)",
    handler: async (args, ctx) => {
      const dir = args.trim().replace(/^~(?=\/|$)/, process.env.HOME ?? "~");
      if (!dir) {
        ctx.ui.notify("usage: /keybase-cd <path>", "info");
        return;
      }
      if (!existsSync(dir) || !statSync(dir).isDirectory()) {
        ctx.ui.notify(`not a directory: ${dir}`, "error");
        if (remote) await sendTo(remote, `🤖 cd failed: not a directory ${dir}`);
        return;
      }
      await ctx.waitForIdle();
      // Prefer the project's most recent session; else create a fresh one
      const sessions = await SessionManager.list(dir);
      sessions.sort((a, b) => Number(new Date(b.modified)) - Number(new Date(a.modified)));
      const target =
        sessions[0]?.path ?? SessionManager.create(dir).getSessionFile();
      await ctx.switchSession(target, {
        withSession: async (ctx2) => {
          ctx2.ui.notify(`cwd: ${dir}`, "info");
        },
      });
    },
  });

  pi.registerCommand("keybase-session-path", {
    description: "Switch this pi to a specific session file path",
    handler: async (args, ctx) => {
      const path = args.trim();
      if (!path) return;
      await ctx.waitForIdle();
      await ctx.switchSession(path, {
        withSession: async (ctx2) => {
          ctx2.ui.notify(`Remote session switched: ${path.split("/").pop()}`, "info");
        },
      });
    },
  });

  pi.registerCommand("keybase-new", {
    description: "Start a fresh session (used by Keybase remote)",
    handler: async (_args, ctx) => {
      await ctx.waitForIdle();
      await ctx.newSession({
        withSession: async (ctx2) => {
          ctx2.ui.notify("Remote session: new session", "info");
        },
      });
    },
  });

  pi.registerCommand("keybase-remote", {
    description: `Toggle remote control via Keybase chat ("${REMOTE_PREFIX} <prompt>" in your self-DM)`,
    getArgumentCompletions: (prefix: string) => {
      const items = ["on", "off"].map((v) => ({ value: v, label: v }));
      const filtered = items.filter((i) => i.value.startsWith(prefix));
      return filtered.length > 0 ? filtered : null;
    },
    handler: async (args, ctx) => {
      const arg = args.trim().toLowerCase();
      if (arg === "on") {
        if (!remote) remote = { me: "", watch: {}, child: null, seen: new Set(), seenQueue: [], active: false, lastAssistant: null, restartTimer: null, stopped: false, restarts: 0, lockPath: null, streamMsgId: null, turnText: "", streamText: "", toolLog: [], lastSentBody: "", lastEditAt: 0, editTimer: null, streamFailed: false, gen: 0, awaitingTurn: false, stoppedByUser: false, sessionSlots: [], dirSlots: [], pendingSums: new Map(), piMode: false, selfSent: new Set() };
        try {
          await startListener(pi);
          remoteOn.current = true;
          ctx.ui.notify("Keybase remote control: on", "info");
        } catch (err) {
          ctx.ui.notify(`Keybase remote control failed: ${String(err)}`, "error");
        }
      } else if (arg === "off") {
        stopListener();
        remoteOn.current = false;
        ctx.ui.notify("Keybase remote control: off", "info");
      } else {
        const chan = remote?.watch?.name ? String(remote.watch.name) : "(not resolved)";
        ctx.ui.notify(
          `Keybase remote control: ${remote?.child ? "on" : "off"}, channel ${chan}, prefix "${REMOTE_PREFIX} "`,
          "info"
        );
      }
    },
  });
}
