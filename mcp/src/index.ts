#!/usr/bin/env node
// fancontrol-mcp: MCP (stdio) -> fand HTTP (127.0.0.1:8765).
// Tools: get_thermal_status, set_fan_speed, boost_fans, set_fan_auto.
// Safety (TTL, clamp, 102C failsafe) is enforced by fand, not here.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const BASE = process.env.FAND_URL ?? "http://127.0.0.1:8765";

async function fand(method: string, path: string, body?: unknown) {
  const r = await fetch(`${BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    // @ts-ignore
    timeout: 9000,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(typeof j?.error === "string" ? j.error : `fand ${r.status}`);
  return j;
}

const server = new McpServer({ name: "fancontrol", version: "0.1.0" });

server.tool("get_thermal_status", "Fans (RPM/mode/range), top die temps, control state + TTL.", {}, async () => {
  try {
    const s = await fand("GET", "/status");
    return { content: [{ type: "text", text: JSON.stringify(s, null, 2) }] };
  } catch (e: any) {
    return { content: [{ type: "text", text: `fand unreachable at ${BASE}: ${e.message}. Start it: sudo fand &` }], isError: true };
  }
});

server.tool(
  "set_fan_speed",
  "Manual fan speed with TTL safety. One of rpm or percent required.",
  {
    rpm: z.number().optional().describe("Target RPM (clamped to hardware range)"),
    percent: z.number().min(0).max(100).optional().describe("Percent of min->max range"),
    fan: z.number().int().min(0).optional().describe("Fan index (default: all)"),
    ttl_seconds: z.number().int().min(60).max(7200).default(900).describe("Auto-revert to macOS control after this long"),
  },
  async ({ rpm, percent, fan, ttl_seconds }) => {
    if (rpm == null && percent == null) throw new Error("provide rpm or percent");
    const r = await fand("POST", "/set", { rpm, percent, fan, ttl_seconds });
    return { content: [{ type: "text", text: JSON.stringify(r, null, 2) }] };
  }
);

server.tool(
  "boost_fans",
  "All fans to 100% for ttl_seconds (pre-cool before builds/inference).",
  { ttl_seconds: z.number().int().min(60).max(7200).default(600) },
  async ({ ttl_seconds }) => {
    const r = await fand("POST", "/boost", { ttl_seconds });
    return { content: [{ type: "text", text: JSON.stringify(r, null, 2) }] };
  }
);

server.tool(
  "set_fan_auto",
  "Release back to macOS control immediately.",
  { fan: z.number().int().min(0).optional() },
  async ({ fan }) => {
    const r = await fand("POST", "/auto", fan != null ? { fan } : {});
    return { content: [{ type: "text", text: JSON.stringify(r, null, 2) }] };
  }
);

await server.connect(new StdioServerTransport());
console.error(`fancontrol-mcp up (fand=${BASE})`);
