/**
 * Worktree Indicator
 *
 * Shows a persistent entry in the footer status bar while the agent is working
 * inside a git linked worktree — the state you're in when /workon or /merge
 * create a PR-producing worktree. Renders:
 *
 *   🌿 <repo>/<worktrees-dir>/<name>  ⎇ <branch>  #<issue>  review ✓ 12m  CI ✓
 *
 * Two extra segments ride along when the worktree is on a real branch:
 *
 *   review ✓ <age>  — a /review (skills/review) run FINISHED for this branch
 *                      (records under ~/.pi/agent/reviews/<repo>/<branch>/);
 *                      age is time since it finished. Warning-colored +
 *                      "(stale)" when HEAD moved since that review. review ◌
 *                      = a run is live now; review ✗ = attempts exist but
 *                      none ever finished; muted review – = never attempted.
 *   CI ✓ / ✗ <name> / ◌ / – — GitHub checks for the branch via gh: PR checks
 *                      when a PR exists, else workflow runs for the pushed
 *                      branch. Muted – = nothing has run. Omitted entirely
 *                      when gh can't answer (not a GitHub repo, no network).
 *                      Polled on a 10s unref'd timer, so the bar (and the
 *                      review age) refresh while the agent is idle; unusable
 *                      gh backs off to one attempt per 60s.
 *
 * Detection tracks the agent's *actual* tool activity, not just the session
 * cwd: when the session is rooted at the main repo (the common case — /workon
 * creates a worktree but cannot cd the caller into it), the agent still
 * operates on the worktree via absolute paths. This extension watches bash /
 * read / write / edit tool calls for `.worktrees/<name>` paths and locks onto
 * the most recently touched worktree. It clears when that worktree disappears
 * from disk (e.g. after /merge) or a different worktree is touched.
 *
 * Auto-discovered from ~/.pi/agent/extensions/. Reloads on /reload.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFile, execSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, dirname, relative, resolve } from "node:path";
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";

// Matches the root of a linked worktree inside a path or command string —
// absolute (`/home/x/repo/.worktrees/name`) or relative (`repo/.worktrees/name`,
// `.worktrees/name`). The leading-boundary class excludes leading command
// text (e.g. `cd `); the name class excludes whitespace/slash/quote/dash
// terminators so trailing ` && ...` on the same line is not swallowed when
// scanning a command rather than a path. Relative hits are resolved against
// the session cwd by the caller.
const WORKTREE_PATH_RE = /(^|[\s="'])(\/?[^\s"']*\/?\.worktrees\/[^/\s"']+)/;

/** Run a git command in `cwd`; return trimmed stdout or null on any failure. */
function git(cwd: string, ...args: string[]): string | null {
	try {
		const out = execSync(["git", ...args].join(" "), {
			cwd,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
			timeout: 2000,
		});
		return out.trim() || null;
	} catch {
		return null;
	}
}

/** True if `wtRoot` is a git linked worktree (`.git` is a regular file). */
function isLinkedWorktree(wtRoot: string): boolean {
	try {
		return statSync(`${wtRoot}/.git`).isFile();
	} catch {
		return false;
	}
}

/**
 * Given a worktree root, gather display info. Returns null if it isn't a real
 * linked worktree or git is unavailable.
 */
function worktreeInfo(
	wtRoot: string,
): { rel: string; repo: string; branch: string } | null {
	if (!isLinkedWorktree(wtRoot)) return null;
	// git-common-dir -> <main-repo>/.git; strip the suffix to get the main root.
	const commonRaw = git(wtRoot, "rev-parse", "--git-common-dir");
	if (!commonRaw) return null;
	const mainRoot = commonRaw.replace(/\/\.git\/?$/, "");
	const branch = git(wtRoot, "branch", "--show-current") || "(detached)";
	let rel = relative(mainRoot, wtRoot);
	if (!rel || rel.startsWith("..")) rel = wtRoot;
	return { rel, repo: basename(mainRoot) || "repo", branch };
}

/** Parse an issue number out of a branch name like `issue-1410-…` or `1410-…`. */
function issueFromBranch(branch: string): string | null {
	const m = branch.match(/(?:^|[-/])issue-(\d+)\b/i) || branch.match(/^(\d+)-/);
	return m ? m[1]! : null;
}

// ---------------------------------------------------------------------------
// Review + CI indicators
// ---------------------------------------------------------------------------

/** Where review.sh records runs (same default as the script; overridable). */
const REVIEWS_DIR = process.env.PI_REVIEWS_DIR || resolve(homedir(), ".pi/agent/reviews");

/** CI is polled on a repeating timer (not just at render time) so the bar
 * updates while the agent is idle. Unusable gh ("unknown") backs off. */
const CI_POLL_MS = 10_000;
const CI_UNKNOWN_BACKOFF_MS = 60_000;

/**
 * Stable per-repo key matching repo_slug() in skills/review/scripts/review.sh:
 * the origin remote's owner/repo, falling back to the main checkout's name.
 */
function repoSlug(wtRoot: string): string | null {
	const raw = git(wtRoot, "config", "--get", "remote.origin.url");
	if (raw) {
		let u = raw.replace(/\.git\/?$/, "");
		u = u.replace(/^[a-z+][a-z0-9+.-]*:\/\//, ""); // scheme:// (https://, ssh://, …)
		u = u.replace(/^[^/:]*:/, ""); // scp-style host (git@host:)
		const parts = u.split("/").filter(Boolean);
		if (parts.length >= 2) return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
	}
	const common = git(wtRoot, "rev-parse", "--git-common-dir");
	if (!common) return null;
	return basename(common.replace(/\/\.git\/?$/, "")) || null;
}

/** Read a tiny `key=value`-per-line file (meta/done markers). Missing → {}. */
function readKv(path: string): Record<string, string> {
	try {
		const out: Record<string, string> = {};
		for (const line of readFileSync(path, "utf8").split("\n")) {
			const i = line.indexOf("=");
			if (i > 0) out[line.slice(0, i)!] = line.slice(i + 1).trimEnd();
		}
		return out;
	} catch {
		return {};
	}
}

function pidAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (e) {
		return (e as NodeJS.ErrnoException).code === "EPERM";
	}
}

/** Compact relative age: now / 12m / 3h / 2d. */
function relTime(tsSec: number): string {
	const s = Math.max(0, Math.floor(Date.now() / 1000 - tsSec));
	if (s < 60) return "now";
	const m = Math.floor(s / 60);
	if (m < 60) return `${m}m`;
	const h = Math.floor(m / 60);
	if (h < 24) return `${h}h`;
	return `${Math.floor(h / 24)}d`;
}

type ReviewState =
	| { status: "running" }
	| { status: "done"; finishedSec: number; stale: boolean }
	| { status: "broken" };

/**
 * Review state for this branch, from review.sh's records — based on what has
 * FINISHED, not merely started. Priority: a live run → running; else the
 * newest completed run (exit 0) → done (age is time since it finished, stale
 * if HEAD moved since ITS recorded head); else started-but-never-finished
 * attempts → broken; null = never reviewed at all.
 */
function reviewRecord(wtRoot: string, branch: string, head: string | null): ReviewState | null {
	const slug = repoSlug(wtRoot);
	if (!slug) return null;
	let entries: string[];
	try {
		entries = readdirSync(resolve(REVIEWS_DIR, slug, branch.replace(/\//g, "-")));
	} catch {
		return null;
	}
	const dirs = entries.filter((n) => /^\d+$/.test(n)).sort(); // asc by start time
	if (!dirs.length) return null;

	let completed: { finishedSec: number; metaHead: string } | null = null;
	let running: { pid: number; startedSec: number } | null = null;
	let attempted = false;
	for (const name of dirs) {
		const runDir = resolve(REVIEWS_DIR, slug, branch.replace(/\//g, "-"), name);
		const done = readKv(resolve(runDir, "done"));
		if (done.finished && (!done.exit || done.exit === "0")) {
			// Ascending scan: each completed run overwrites the last, so the
			// newest finished review wins.
			completed = {
				finishedSec: Number(done.finished) || 0,
				metaHead: readKv(resolve(runDir, "meta")).head ?? "",
			};
			continue;
		}
		attempted = true; // failed exit, or unfinished
		const pid = Number(readKv(resolve(runDir, "pid")).pid);
		if (!done.finished && pid > 0 && pidAlive(pid)) running = { pid, startedSec: Number(name) };
	}

	// A live run only outranks a finished review when it started AFTER that
	// review finished — an older still-"running" entry is abandoned (stuck
	// pid / reused pid), not news.
	if (running && (!completed || running.startedSec >= completed.finishedSec)) {
		return { status: "running" };
	}
	if (completed) {
		return {
			status: "done",
			finishedSec: completed.finishedSec,
			stale: Boolean(head && completed.metaHead && completed.metaHead !== head),
		};
	}
	if (attempted) return { status: "broken" };
	return null;
}

type CiStatus = "green" | "red" | "pending" | "none" | "unknown";
let ciCache: { key: string; status: CiStatus; detail?: string; at: number } | null = null;
let ciBusy = false;

/** Aggregate `gh pr checks --json bucket,name` rows. */
function combineChecks(rows: Array<{ bucket?: string; name?: string }>): { status: CiStatus; detail?: string } {
	const fail = rows.find((r) => r.bucket === "fail" || r.bucket === "cancel");
	if (fail) return { status: "red", detail: fail.name };
	if (rows.some((r) => r.bucket === "pending")) return { status: "pending" };
	return { status: "green" }; // only pass/skipping left
}

/** Aggregate `gh run list --json status,conclusion,workflowName` rows (newest first). */
const BAD_CONCLUSIONS = ["failure", "timed_out", "startup_failure", "cancelled"];
function combineRuns(
	rows: Array<{ status?: string; conclusion?: string | null; workflowName?: string }>,
): { status: CiStatus; detail?: string } {
	const bad = rows.find((r) => r.conclusion && BAD_CONCLUSIONS.includes(r.conclusion!));
	if (bad) return { status: "red", detail: bad.workflowName };
	if (rows.some((r) => !r.conclusion)) return { status: "pending" }; // in_progress / queued
	if (rows.some((r) => r.conclusion === "success")) return { status: "green" };
	return { status: "none" };
}

/** Parse JSON stdout safely; gh exits non-zero for pending/failed checks. */
function safeJson(out: string): unknown {
	try {
		return JSON.parse(out);
	} catch {
		return null;
	}
}

/**
 * Fetch CI state for the branch off the UI thread; re-render when it lands.
 * PR checks first (works pre-push once the PR exists); workflow runs for the
 * branch as the no-PR fallback (pushed branches). "unknown" (gh unusable)
 * omits the segment entirely.
 */
function kickCiFetch(wtRoot: string, branch: string, key: string, ctx: ExtensionContext): void {
	if (ciBusy) return;
	ciBusy = true;
	const opts = { cwd: wtRoot, timeout: 15_000 };
	const settle = (status: CiStatus, detail?: string) => {
		ciCache = { key, status, detail, at: Date.now() };
		ciBusy = false;
		render(ctx);
	};
	execFile("gh", ["pr", "checks", branch, "--json", "bucket,name"], opts, (err, stdout) => {
		const checks = safeJson(stdout ?? "");
		if (Array.isArray(checks) && checks.length) {
			const { status, detail } = combineChecks(checks);
			settle(status, detail);
			return;
		}
		execFile("gh", ["run", "list", "--branch", branch, "--limit", "5", "--json", "status,conclusion,workflowName"], opts, (_e2, out2) => {
			const runs = safeJson(out2 ?? "");
			if (!Array.isArray(runs)) {
				settle("unknown");
				return;
			}
			if (!runs.length) {
				settle("none");
				return;
			}
			const { status, detail } = combineRuns(runs);
			settle(status, detail);
		});
	});
}

/** CI segment string, or null to omit (gh can't answer / nothing cached yet is shown muted). */
function ciSegment(wtRoot: string, branch: string, head: string, ctx: ExtensionContext): string | null {
	const t = ctx.ui.theme;
	const key = `${wtRoot}|${branch}|${head}`;
	if (!ciCache || ciCache.key !== key || Date.now() - ciCache.at > CI_POLL_MS) kickCiFetch(wtRoot, branch, key, ctx);
	if (!ciCache || ciCache.key !== key) return t.fg("muted", "CI …");
	const c = ciCache;
	if (c.status === "green") return t.fg("success", "CI ✓");
	if (c.status === "red") return t.fg("error", `CI ✗${c.detail ? ` ${c.detail.slice(0, 16)}` : ""}`);
	if (c.status === "pending") return t.fg("warning", "CI ◌");
	if (c.status === "none") return t.fg("muted", "CI –");
	return null; // unknown — gh unusable for this repo
}

// Absolute path of the worktree root we're currently showing (if any).
// Persists across turns until the worktree is removed or a different one is
// touched — the agent rarely switches worktrees mid-session, so this avoids
// flicker.
let current: string | null = null;

// Latest context (for timer-driven renders) and the CI poll timer. The timer
// is unref'd so it never keeps the process alive.
let lastCtx: ExtensionContext | null = null;
let lastStatusStr: string | null = null;
let ciPollTimer: NodeJS.Timeout | null = null;

function stopPoll(): void {
	if (ciPollTimer) {
		clearInterval(ciPollTimer);
		ciPollTimer = null;
	}
}

/** One poll tick: refresh CI for the locked worktree, then re-render (also
 * refreshes review state and the time-since-reviewed age while idle). */
function pollTick(): void {
	if (!current || !lastCtx) {
		stopPoll();
		return;
	}
	const branch = git(current, "branch", "--show-current");
	if (!branch || branch === "(detached)") return;
	const head = git(current, "rev-parse", "HEAD");
	if (!head) return;
	const key = `${current}|${branch}|${head}`;
	// Back off when gh can't answer for this repo — retry the same key rarely.
	if (ciCache?.status === "unknown" && ciCache.key === key && Date.now() - ciCache.at < CI_UNKNOWN_BACKOFF_MS) {
		return;
	}
	kickCiFetch(current, branch, key, lastCtx);
	render(lastCtx);
}

function startPoll(): void {
	if (ciPollTimer) return;
	ciPollTimer = setInterval(pollTick, CI_POLL_MS);
	ciPollTimer.unref?.();
}

/**
 * Recover the lock across /reload ONLY: module state dies with a reload
 * (fresh import), and session_start can only re-seed from the session cwd —
 * which is usually the *main* repo, not the worktree. Fresh sessions must NOT
 * inherit this: the bar tracks *this* session's actual activity, and a new
 * session that never touches a worktree should show nothing at all.
 */
const STATE_FILE = resolve(homedir(), ".pi/agent/worktree-indicator-state.json");

function loadState(): Record<string, { worktree: string; at: number }> {
	try {
		return JSON.parse(readFileSync(STATE_FILE, "utf8"));
	} catch {
		return {};
	}
}

function persistLock(mainRoot: string, wtRoot: string): void {
	try {
		const state = loadState();
		state[mainRoot] = { worktree: wtRoot, at: Date.now() };
		// Prune dead entries; keep only the most recent 50.
		const alive = Object.entries(state)
			.filter(([, v]) => existsSync(v.worktree))
			.sort((a, b) => b[1].at - a[1].at)
			.slice(0, 50);
		mkdirSync(dirname(STATE_FILE), { recursive: true });
		writeFileSync(STATE_FILE, JSON.stringify(Object.fromEntries(alive), null, "\t"));
	} catch {
		// State persistence is best-effort; never break rendering over it.
	}
}

/** Main-repo root for a worktree (from the shared git dir), or null. */
function mainRootOf(wtRoot: string): string | null {
	const common = git(wtRoot, "rev-parse", "--git-common-dir");
	if (!common) return null;
	return resolve(wtRoot, common).replace(/\/\.git\/?$/, "") || null;
}

/**
 * Render the footer status for the locked-on worktree. Module-level (not
 * closed over in the extension factory) so the async CI fetch callback can
 * re-render when a result lands.
 */
function render(ctx: ExtensionContext): void {
	if (!ctx.hasUI) return;
	lastCtx = ctx;

	let info: { rel: string; repo: string; branch: string } | null = null;
	if (current && existsSync(current) && isLinkedWorktree(current)) {
		info = worktreeInfo(current);
		if (!info) current = null; // was a worktree, no longer valid
	} else {
		current = null;
	}

	if (!info || !current) {
		stopPoll();
		if (lastStatusStr !== null) {
			lastStatusStr = null;
			ctx.ui.setStatus("worktree-indicator", undefined);
		}
		return;
	}

	const t = ctx.ui.theme;
	const parts: string[] = [
		t.fg("accent", "🌿"),
		t.fg("accent", `${info.repo}/${info.rel}`),
		t.fg("muted", "⎇"),
		t.fg("success", info.branch),
	];
	const issue = issueFromBranch(info.branch);
	if (issue) parts.push(t.fg("accent", `#${issue}`));

	// Review + CI segments (skipped on detached HEAD — nothing to key them to).
	let pollable = false;
	if (info.branch !== "(detached)") {
		const head = git(current, "rev-parse", "HEAD");
		if (head) {
			pollable = true;
			const rv = reviewRecord(current, info.branch, head);
			parts.push(
				rv?.status === "done"
				? t.fg(rv.stale ? "warning" : "success", `review ✓ ${relTime(rv.finishedSec)}${rv.stale ? " (stale)" : ""}`)
				: rv?.status === "running"
					? t.fg("accent", "review ◌")
					: rv?.status === "broken"
						? t.fg("error", "review ✗")
						: t.fg("muted", "review –"),
			);
			const ci = ciSegment(current, info.branch, head, ctx);
			if (ci) parts.push(ci);
		}
	}

	// Keep the 10s poll running only while there is something live to show.
	if (pollable) startPoll();
	else stopPoll();

	// Dedupe identical strings so the poll can re-render freely without UI churn.
	const str = parts.join("  ");
	if (str !== lastStatusStr) {
		lastStatusStr = str;
		ctx.ui.setStatus("worktree-indicator", str);
	}
}

export default function worktreeIndicator(pi: ExtensionAPI): void {
	/** Scan a blob of text (a command or path) for a `.worktrees/<name>` root. */
	function extractWorktreeRoot(text: string, cwd: string): string | null {
		const m = text.match(WORKTREE_PATH_RE);
		if (!m) return null;
		// Resolve relative hits (`.worktrees/name`, `repo/.worktrees/name`)
		// against the session cwd — tool paths and commands are frequently
		// relative, which the old absolute-only regex never matched.
		return resolve(cwd, m[2]!);
	}

	/** Lock onto a worktree root: set module state, persist, re-render. */
	function lockOn(root: string, ctx: ExtensionContext): void {
		current = root;
		const mainRoot = mainRootOf(root);
		if (mainRoot) persistLock(mainRoot, root);
		render(ctx);
	}

	pi.on("session_start", async (event, ctx) => {
		// Seed from cwd in case pi was launched from inside a worktree dir…
		const cwdRoot = git(ctx.cwd, "rev-parse", "--show-toplevel");
		if (cwdRoot && isLinkedWorktree(cwdRoot)) {
			lockOn(cwdRoot, ctx);
			return;
		}
		// …else recover the lock this session held, but only for /reload — the
		// same session whose module state just got wiped. A new/resumed session
		// starts clean: no inherited worktree until the agent actually touches
		// a `.worktrees/<name>` path.
		if (event.reason === "reload" && !current && cwdRoot) {
			const mainRoot = mainRootOf(cwdRoot);
			const saved = mainRoot ? loadState()[mainRoot] : undefined;
			if (saved && isLinkedWorktree(saved.worktree)) {
				lockOn(saved.worktree, ctx);
				return;
			}
		}
		render(ctx);
	});

	// Refresh without tool activity (review age, CI TTL, lock recovery) — fires
	// on every user message. render() is cheap: local git/fs reads, cached CI.
	pi.on("turn_start", async (_event, ctx) => {
		render(ctx);
	});

	/**
	 * Pull the path/command blob out of a tool input for the tools that
	 * carry filesystem paths. Returns "" for anything else. Shared by the
	 * tool_call and tool_result handlers, whose input types differ.
	 */
	function blobFromInput(toolName: string, input: { command?: unknown; path?: unknown }): string {
		if (toolName === "bash") return typeof input.command === "string" ? input.command : "";
		if (toolName === "read" || toolName === "write" || toolName === "edit") {
			return typeof input.path === "string" ? input.path : "";
		}
		// grep / ls / find also take path-ish args but with varied shapes; the
		// four tools above cover the overwhelming majority of worktree access.
		return "";
	}

	/** Scan a tool's input for a `.worktrees/<name>` root and lock onto it. */
	function scanToolInput(
		toolName: string,
		input: { command?: unknown; path?: unknown },
		ctx: ExtensionContext,
	): void {
		const blob = blobFromInput(toolName, input);
		if (!blob) return;

		const root = extractWorktreeRoot(blob, ctx.cwd);
		if (!root || !isLinkedWorktree(root)) return;
		if (root !== current) lockOn(root, ctx);
	}

	// Lock onto the worktree the agent is actually operating in. Watches the
	// tools that carry filesystem paths / commands, so it tracks real activity
	// even when the session cwd stays at the main repo.
	pi.on("tool_call", async (event, ctx) => {
		scanToolInput(event.toolName, event.input, ctx);
	});

	// tool_call fires *before* execution, so a worktree created by the very
	// command being scanned (`git worktree add .worktrees/foo`) doesn't exist
	// yet and is skipped by the isLinkedWorktree check. Re-scan the same input
	// once the tool has finished to catch freshly created worktrees.
	pi.on("tool_result", async (event, ctx) => {
		scanToolInput(event.toolName, event.input, ctx);
	});

	pi.on("session_shutdown", async () => {
		stopPoll();
		lastCtx = null;
	});
}
