#!/usr/bin/env node

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { JsonStore, ReviewCanvasService, defaultStorePath } from "../src/index.js";
import { createReviewCanvasMcpServer } from "../src/mcp-server.js";

async function main() {
  const store = new JsonStore(defaultStorePath());
  await store.recoverInterruptedQueues();
  const service = new ReviewCanvasService({ store });
  const server = createReviewCanvasMcpServer({
    service,
    reportError: (error) => {
      const detail =
        process.env.REVIEW_CANVAS_DEBUG === "1" && error instanceof Error
          ? `: ${error.message}`
          : "";
      process.stderr.write(`Review Canvas MCP internal error${detail}\n`);
    },
  });
  const transport = new StdioServerTransport(process.stdin, process.stdout, {
    maxBufferSize: 8 * 1024 * 1024,
  });

  await server.connect(transport);
}

main().catch((error) => {
  const detail =
    process.env.REVIEW_CANVAS_DEBUG === "1" && error instanceof Error
      ? `: ${error.message}`
      : "";
  process.stderr.write(`Review Canvas MCP failed to start${detail}\n`);
  process.exitCode = 1;
});
