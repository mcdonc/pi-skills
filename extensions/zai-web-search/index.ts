import { keyHint, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { Text } from "@earendil-works/pi-tui";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

// Z.AI Web Search remote MCP server.
// Docs: https://docs.z.ai/devpack/mcp/search-mcp-server
const MCP_URL = process.env.ZAI_MCP_URL ?? "https://api.z.ai/api/mcp/web_search_prime/mcp";

// JSON-Schema object describing a tool's arguments.
type InputSchema = { type: "object"; properties?: Record<string, unknown> };

type DiscoveredTool = { name: string; description?: string; inputSchema?: InputSchema };

export default function (pi: ExtensionAPI) {
  let clientPromise: Promise<Client> | null = null;
  let discoveredTools: DiscoveredTool[] | null = null;

  // Z.AI auth token lives in the agenix-decrypted file created by the NixOS
  // config (age.secrets."zai-authtoken" -> /run/agenix/zai-authtoken).
  // Allow ZAI_API_KEY to override with a literal key or alternate file path.
  const AUTHTOKEN_FILE = process.env.ZAI_API_KEY ?? "/run/agenix/zai-authtoken";
  function resolveApiKey(): string {
    const raw = AUTHTOKEN_FILE.trim();
    if (existsSync(raw)) {
      return readFileSync(raw, "utf8").trim();
    }
    if (!raw) {
      throw new Error(
        `Z.AI auth token file not found at ${AUTHTOKEN_FILE}. Ensure the agenix secret "zai-authtoken" is declared for this host. Get a key from https://docs.z.ai/devpack/overview`
      );
    }
    return raw;
  }

  async function getClient(): Promise<Client> {
    if (!clientPromise) {
      clientPromise = (async () => {
        const apiKey = resolveApiKey();
        const client = new Client({ name: "pi-zai-web-search", version: "1.0.0" });
        const transport = new StreamableHTTPClientTransport(new URL(MCP_URL), {
          requestInit: {
            headers: { Authorization: `Bearer ${apiKey}` },
          },
        });
        await client.connect(transport);
        return client;
      })().catch((err) => {
        clientPromise = null; // allow retry on next call
        throw err;
      });
    }
    return clientPromise;
  }

  // Discover tools from the server (paginated) and cache them.
  async function discoverTools(): Promise<DiscoveredTool[]> {
    if (discoveredTools) return discoveredTools;
    const client = await getClient();
    const tools: DiscoveredTool[] = [];
    let cursor: string | undefined;
    do {
      const page = await client.listTools({ cursor }, { timeout: SEARCH_TIMEOUT_MS });
      for (const t of page.tools) {
        tools.push({
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema as InputSchema | undefined,
        });
      }
      cursor = page.nextCursor;
    } while (cursor);
    discoveredTools = tools;
    return tools;
  }

  // Pick the best tool name for a web-search call.
  // Strategy: exact "webSearchPrime" → contains "search" → otherwise the only tool.
  function pickSearchToolName(tools: DiscoveredTool[]): string {
    if (tools.length === 0) {
      throw new Error("Z.AI MCP server exposed no tools. Check your plan / API key.");
    }
    const exact = tools.find((t) => t.name === "webSearchPrime");
    if (exact) return exact.name;
    const bySearch = tools.find((t) => t.name.toLowerCase().includes("search"));
    if (bySearch) return bySearch.name;
    if (tools.length === 1) return tools[0]!.name;
    throw new Error(
      "Could not identify the web-search tool. Available: " +
        tools.map((t) => t.name).join(", ") +
        ". Run /zai-tools to see them."
    );
  }

  // Render z.ai's results (a JSON-encoded string inside one text block) as
  // clean markdown. Falls back to raw text if the shape isn't recognized.
  type RawResult = {
    title?: string;
    link?: string;
    url?: string;
    content?: string;
    snippet?: string;
    refer?: string;
    [k: string]: unknown;
  };
  function renderResults(rawText: string): { markdown: string; parsed: RawResult[] | null } {
    // The z.ai server is inconsistent about encoding depth: the array may be
    // single-encoded (`[{...}]`), or double/triple-encoded (a JSON string
    // whose value is itself JSON). Unwrap layers until we hit an object/array.
    let text: unknown = rawText.trim();
    let arr: unknown;
    for (let i = 0; i < 3 && typeof text === "string"; i++) {
      try {
        arr = JSON.parse(text);
      } catch {
        arr = undefined;
        break;
      }
      if (typeof arr === "string") {
        text = arr; // another layer to unwrap
        continue;
      }
      break;
    }
    const items: RawResult[] | null = Array.isArray(arr)
      ? (arr as RawResult[])
      : Array.isArray((arr as any)?.results)
        ? ((arr as any).results as RawResult[])
        : null;
    if (!items || items.length === 0) return { markdown: rawText, parsed: null };
    const lines: string[] = [];
    items.forEach((item, i) => {
      const title = item.title ?? "(untitled)";
      const url = item.link ?? item.url ?? "";
      const snippet = (item.content ?? item.snippet ?? "").toString().trim();
      lines.push(`### ${i + 1}. ${title}`);
      if (url) lines.push(`<${url}>`);
      if (snippet) lines.push("", snippet);
      if (i < items.length - 1) lines.push("");
    });
    return { markdown: lines.join("\n"), parsed: items };
  }

  // Map our generic `query` param onto the real argument name declared by the
  // tool's inputSchema. The z.ai server uses `search_query`, not `query`.
  const SEARCH_PARAM_HINTS = ["search_query", "searchquery", "query", "q", "search"];
  function pickSearchParamName(tool: DiscoveredTool): string {
    const props = tool.inputSchema?.properties;
    if (props) {
      const names = Object.keys(props);
      for (const hint of SEARCH_PARAM_HINTS) {
        const match = names.find((n) => n.toLowerCase() === hint);
        if (match) return match;
      }
      // Fallback: first string-typed property.
      for (const [name, schema] of Object.entries(props)) {
        if ((schema as any)?.type === "string") return name;
      }
      if (names.length === 1) return names[0]!;
    }
    return SEARCH_PARAM_HINTS[0]!; // last resort: the documented name
  }

  // The z.ai remote MCP server is slow under concurrent load and the SDK's
  // default 60s request timeout fires (MCP error -32001). Raise the per-request
  // timeout and retry once on transient failure (timeout / connection drop).
  const SEARCH_TIMEOUT_MS = 120_000;
  async function callSearchWithRetry(
    client: Client,
    toolName: string,
    args: Record<string, unknown>,
    signal: AbortSignal | undefined
  ) {
    let lastErr: unknown;
    for (let attempt = 0; attempt < 2; attempt++) {
      if (signal?.aborted) throw new Error("cancelled");
      try {
        return await client.callTool(
          { name: toolName, arguments: args },
          undefined,
          { signal, timeout: SEARCH_TIMEOUT_MS }
        );
      } catch (err) {
        lastErr = err;
        if (attempt === 1 || signal?.aborted) break;
        await new Promise((r) => setTimeout(r, 750));
      }
    }
    throw lastErr;
  }

  pi.registerTool({
    name: "zai_web_search",
    label: "Z.AI Web Search",
    description:
      "Search the live web via Z.AI's Web Search MCP server. " +
      "Returns page titles, URLs, summaries, site names, and icons.",
    promptSnippet: "Search the live web using Z.AI web search",
    parameters: Type.Object({
      query: Type.String({ description: "The web search query." }),
    }),
    async execute(_toolCallId, params, signal) {
      const client = await getClient();
      const tools = await discoverTools();
      const toolName = pickSearchToolName(tools);
      const tool = tools.find((t) => t.name === toolName)!;
      const paramName = pickSearchParamName(tool);

      const result = await callSearchWithRetry(
        client,
        toolName,
        { [paramName]: params.query },
        signal
      );

      // Coalesce all text blocks (z.ai puts the whole JSON payload in one),
      // parse it, and render as markdown. Non-text blocks pass through.
      let parsedResults: RawResult[] | null = null;
      const content = ((result.content ?? []) as any[]).map((block) => {
        if (block.type === "image") return block;
        if (block.type !== "text") {
          return { type: "text", text: JSON.stringify(block) };
        }
        const { markdown, parsed } = renderResults(block.text ?? "");
        if (parsed && !parsedResults) parsedResults = parsed;
        return { type: "text", text: markdown };
      });

      return {
        content,
        details: {
          isError: result.isError ?? false,
          calledTool: toolName,
          calledParam: paramName,
          resultCount: (parsedResults as RawResult[] | null)?.length ?? 0,
          // Compact list of {title,url} for machine use / link harvesting.
          links: ((parsedResults as RawResult[] | null) ?? []).map((r) => ({
            title: r.title ?? "",
            url: r.link ?? r.url ?? "",
          })),
          structuredContent: result.structuredContent,
        },
      };
    },
    // Pane display: compact one-liner by default, clean link list on expand.
    // The raw JSON / full markdown never reaches the TUI — `content` (what the
    // model gets) is separate from what this renders (what you see).
    renderResult(result, { expanded, isPartial }, theme, context) {
      const args = (context.args ?? {}) as { query?: string };
      const details = (result.details ?? {}) as {
        resultCount?: number;
        links?: Array<{ title?: string; url?: string }>;
      };
      const query = args.query?.trim() ?? "";
      const count = details.resultCount ?? 0;

      if (isPartial) {
        return new Text(theme.fg("warning", "⠋ searching the web…"), 0, 0);
      }
      if (context.isError || count === 0) {
        const msg = `✗ no results${query ? ` for "${query}"` : ""}`;
        return new Text(theme.fg("error", msg), 0, 0);
      }

      let text =
        theme.fg("success", `✓ ${count} web result${count === 1 ? "" : "s"}`) +
        (query ? theme.fg("muted", `  for "${query}"`) : "");

      if (!expanded) {
        text += "  " + keyHint("app.tools.expand", "expand for links");
        return new Text(text, 0, 0);
      }

      for (const link of details.links ?? []) {
        const title = link.title?.trim() || "(untitled)";
        const url = link.url?.trim();
        text += "\n  " + theme.fg("dim", url ? `${title} — ${url}` : title);
      }
      return new Text(text, 0, 0);
    },
  });

  // Debug command: list what the server actually exposes.
  pi.registerCommand("zai-tools", {
    description: "List tools exposed by the Z.AI Web Search MCP server",
    handler: async (_args, ctx) => {
      try {
        const tools = await discoverTools();
        if (tools.length === 0) {
          ctx.ui.notify("Z.AI MCP server exposed no tools.", "warning");
          return;
        }
        const lines = tools.map((t) => {
          const params = t.inputSchema?.properties
            ? Object.keys(t.inputSchema.properties).join(", ")
            : "(no schema)";
          return `  • ${t.name}  [${params}]${t.description ? "\n      " + t.description : ""}`;
        });
        ctx.ui.notify(["Z.AI MCP tools:", ...lines].join("\n"), "info");
      } catch (err: any) {
        ctx.ui.notify(`Failed to list Z.AI tools: ${err.message}`, "error");
      }
    },
  });

  // Debug command: run one search and dump the raw shape of each content
  // block to /tmp/zai-debug.txt so we can verify how the server actually
  // encodes results (single vs double JSON) and confirm the parser works.
  pi.registerCommand("zai-raw", {
    description: "Run a Z.AI search and dump raw content-block shape to /tmp/zai-debug.txt",
    handler: async (args, ctx) => {
      const query = (args || "docker sandbox").trim();
      try {
        const client = await getClient();
        const tools = await discoverTools();
        const toolName = pickSearchToolName(tools);
        const tool = tools.find((t) => t.name === toolName)!;
        const paramName = pickSearchParamName(tool);
        const result = await callSearchWithRetry(client, toolName, { [paramName]: query }, undefined);
        const blocks = (result.content ?? []) as any[];
        const lines: string[] = [
          `query: ${query}`,
          `tool: ${toolName} (${paramName})`,
          `isError: ${result.isError ?? false}`,
          `content blocks: ${blocks.length}`,
          "",
        ];
        blocks.forEach((block, i) => {
          const text = typeof block.text === "string" ? block.text : "";
          const { parsed } = renderResults(text);
          lines.push(`--- block ${i} ---`);
          lines.push(`type: ${block.type}`);
          lines.push(`typeof text: ${typeof block.text}`);
          lines.push(`text length: ${text.length}`);
          lines.push(`first 3 chars (JSON.stringify): ${JSON.stringify(text.slice(0, 3))}`);
          lines.push(`parsed item count: ${parsed?.length ?? 0}`);
          lines.push(`raw text first 500 chars: ${JSON.stringify(text.slice(0, 500))}`);
          lines.push("");
        });
        writeFileSync("/tmp/zai-debug.txt", lines.join("\n"));
        ctx.ui.notify(
          `Wrote /tmp/zai-debug.txt — ${blocks.length} block(s), see file for shape.`,
          "info"
        );
      } catch (err: any) {
        ctx.ui.notify(`zai-raw failed: ${err.message}`, "error");
      }
    },
  });

  pi.on("session_shutdown", async () => {
    const pending = clientPromise;
    clientPromise = null;
    discoveredTools = null;
    if (pending) {
      try {
        await (await pending).close();
      } catch {
        /* ignore */
      }
    }
  });
}
