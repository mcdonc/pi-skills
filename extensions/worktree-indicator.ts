/**
 * Worktree Indicator
 *
 * Shows a persistent entry in the footer status bar while the agent is working
 * inside a git linked worktree — the state you're in when /workon or /merge
 * create a PR-producing worktree. Renders:
 *
 *   🌿 <repo>/<worktrees-dir>/<name>  ⎇ <branch>  #<issue>
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
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { basename, relative, resolve } from "node:path";
import { existsSync, statSync } from "node:fs";

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

export default function worktreeIndicator(pi: ExtensionAPI): void {
	// Absolute path of the worktree root we're currently showing (if any).
	// Persists across turns until the worktree is removed or a different one
	// is touched — the agent rarely switches worktrees mid-session, so this
	// avoids flicker.
	let current: string | null = null;

	function render(ctx: ExtensionContext): void {
		if (!ctx.hasUI) return;

		let info: { rel: string; repo: string; branch: string } | null = null;
		if (current && existsSync(current) && isLinkedWorktree(current)) {
			info = worktreeInfo(current);
			if (!info) current = null; // was a worktree, no longer valid
		} else {
			current = null;
		}

		if (!info || !current) {
			ctx.ui.setStatus("worktree-indicator", undefined);
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

		ctx.ui.setStatus("worktree-indicator", parts.join("  "));
	}

	/** Scan a blob of text (a command or path) for a `.worktrees/<name>` root. */
	function extractWorktreeRoot(text: string, cwd: string): string | null {
		const m = text.match(WORKTREE_PATH_RE);
		if (!m) return null;
		// Resolve relative hits (`.worktrees/name`, `repo/.worktrees/name`)
		// against the session cwd — tool paths and commands are frequently
		// relative, which the old absolute-only regex never matched.
		return resolve(cwd, m[2]!);
	}

	pi.on("session_start", async (_event, ctx) => {
		// In case pi was launched from inside a worktree dir, seed from cwd.
		const cwdRoot = git(ctx.cwd, "rev-parse", "--show-toplevel");
		if (cwdRoot && isLinkedWorktree(cwdRoot)) current = cwdRoot;
		render(ctx);
	});

	// Lock onto the worktree the agent is actually operating in. Watches the
	// tools that carry filesystem paths / commands, so it tracks real activity
	// even when the session cwd stays at the main repo.
	pi.on("tool_call", async (event, ctx) => {
		let blob = "";
		if (isToolCallEventType("bash", event)) {
			blob = event.input.command ?? "";
		} else if (
			isToolCallEventType("read", event) ||
			isToolCallEventType("write", event) ||
			isToolCallEventType("edit", event)
		) {
			blob = event.input.path ?? "";
		}
		// grep / ls / find also take path-ish args but with varied shapes; the
		// four tools above cover the overwhelming majority of worktree access.
		if (!blob) return;

		const root = extractWorktreeRoot(blob, ctx.cwd);
		if (!root || !isLinkedWorktree(root)) return;
		if (root !== current) {
			current = root;
			render(ctx);
		}
	});

	pi.on("session_shutdown", async () => {
		// Status slots are per-session; nothing to clean up.
	});
}
