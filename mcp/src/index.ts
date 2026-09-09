#!/usr/bin/env node
// fancontrol-mcp: MCP (stdio) -> fand HTTP (127.0.0.1:8765).
// SAFE SUBSET ONLY: get_thermal_status, max_fans, set_fan_auto.
// There is deliberately NO tool for low/custom RPM — agents can only
// request Max (TTL-guarded) or hand back to macOS Auto.
// Safety (TTL, Max-only, 102C failsafe) is enforced by fand, not here.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const BASE = process.env.FAND_URL ?? "http://127.0.0.1:8765";

async function fand(method: string, path: string, body?: unknown) {
  const r = await fetch(`${BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15_000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(typeof j?.error === "string" ? j.error : `fand ${r.status}`);
  return j;
}

const server = new McpServer({ name: "fancontrol", version: "0.3.0" });

server.tool("get_thermal_status", "Fans (RPM/mode/range), top die temps, control state + TTL.", {}, async () => {
  try {
    const s = await fand("GET", "/status");
    return { content: [{ type: "text", text: JSON.stringify(s, null, 2) }] };
  } catch (e: any) {
    return { content: [{ type: "text", text: `fand unreachable at ${BASE}: ${e.message}. Start it: sudo fand &` }], isError: true };
  }
});

server.tool(
  "max_fans",
  "All fans to HARDWARE MAXIMUM for ttl_seconds (pre-cool before builds/inference). Auto-reverts to macOS control after TTL. Verifies each fan reached the RPM it was commanded to (reports before/after per fan) — a fan that was already fast is no longer mistaken for success. This is the ONLY speed change available; low/custom speeds are not expressible.",
  { ttl_seconds: z.number().int().min(60).max(7200).default(900).describe("Auto-revert to macOS control after this long (default 15 min, max 2 h)") },
  async ({ ttl_seconds }) => {
    const r: any = await fand("POST", "/max", { ttl_seconds });
    const json = JSON.stringify(r, null, 2);
    if (r && r.spunUp === false) {
      const stuck = Array.isArray(r.spinUpCheck)
        ? r.spinUpCheck.filter((f: any) => f.reached === false)
            .map((f: any) => `fan${f.index}: ${Math.round(f.actualRPM)} of ${Math.round(f.commandedRPM)} rpm`)
            .join(", ")
        : "";
      return {
        content: [{ type: "text", text: `WARNING: fans did not reach commanded maximum within the spin-up window${stuck ? ` (${stuck})` : ""}. Control is still TTL-guarded and auto-reverts in ${ttl_seconds}s.\n${json}` }],
      };
    }
    return { content: [{ type: "text", text: json }] };
  }
);

server.tool(
  "set_fan_auto",
  "Release back to macOS control immediately (the default state).",
  {},
  async () => {
    const r = await fand("POST", "/auto", {});
    return { content: [{ type: "text", text: JSON.stringify(r, null, 2) }] };
  }
);

await server.connect(new StdioServerTransport());
console.error(`fancontrol-mcp up (fand=${BASE})`);
