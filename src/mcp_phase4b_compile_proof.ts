/**
 * Hospitality Phase 4B — Compile-Time Proof (MCP via ago-1-core)
 *
 * This file intentionally does NOT execute at runtime.
 * It proves Hospitality can build a valid MCP tool request using the core Nexus plane.
 */
import { mcp } from "ago-1-core";

export function hospitalityMcpCompileProof() {
  const transport = mcp.createHttpToolTransport({ baseUrl: "http://127.0.0.1:8787" });

  const req: mcp.ToolRequest = {
    tool: "shared.artifact_registry.read",
    args: {},
    ctx: {
      tenant: "shared",
      actor: "hospitality-ago-1",
      purpose: "hospitality-phase4b-compile-proof",
      classification: "internal",
      traceId: "hospitality-compile-proof"
    }
  };

  // Compile-time validation of call shape + policy surface.
  void mcp.callTool(transport, req);
}
