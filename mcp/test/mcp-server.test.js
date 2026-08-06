import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { createReviewCanvasMcpServer } from "../src/mcp-server.js";
import { JsonStore, ReviewCanvasService } from "../src/index.js";
import {
  DIAGRAM_ID,
  INITIAL_REVISION_ID,
  NEXT_REVISION_ID,
  sequenceIdGenerator,
  withTemporaryDirectory,
} from "./helpers.js";

const NOW = "2026-08-05T01:23:45.000Z";
const MCP_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function withMcpClient(run) {
  return withTemporaryDirectory(async (directory) => {
    const store = new JsonStore(path.join(directory, "store.json"), { now: () => NOW });
    const service = new ReviewCanvasService({
      store,
      now: () => NOW,
      idGenerator: sequenceIdGenerator([
        DIAGRAM_ID,
        INITIAL_REVISION_ID,
        NEXT_REVISION_ID,
      ]),
    });
    const server = createReviewCanvasMcpServer({ service });
    const client = new Client({ name: "review-canvas-test", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

    await server.connect(serverTransport);
    await client.connect(clientTransport);
    try {
      await run({ client, store });
    } finally {
      await client.close();
      await server.close();
    }
  });
}

describe("Review Canvas MCP tools", () => {
  it("requires a service", () => {
    assert.throws(() => createReviewCanvasMcpServer(), { name: "TypeError" });
  });

  it("advertises exactly the four local review tools with closed schemas", async () => {
    await withMcpClient(async ({ client }) => {
      const { tools } = await client.listTools();

      assert.deepEqual(
        tools.map((tool) => tool.name),
        ["send_diagram", "list_review_marks", "propose_revision", "resolve_review_mark"],
      );
      assert.equal(tools[0].inputSchema.additionalProperties, false);
      assert.deepEqual(tools[0].inputSchema.required, ["title", "mermaid"]);
      assert.equal(tools[1].annotations.readOnlyHint, true);
      assert.equal(tools[0].annotations.openWorldHint, false);
    });
  });

  it("returns structured output for send_diagram and propose_revision", async () => {
    await withMcpClient(async ({ client, store }) => {
      const sent = await client.callTool({
        name: "send_diagram",
        arguments: {
          title: "Auth flow",
          mermaid: "sequenceDiagram\n User->>API: Sign in",
        },
      });
      assert.equal(sent.isError, undefined);
      assert.deepEqual(sent.structuredContent, {
        diagramId: DIAGRAM_ID,
        revisionId: INITIAL_REVISION_ID,
        status: "queued",
      });

      const proposed = await client.callTool({
        name: "propose_revision",
        arguments: {
          diagramId: DIAGRAM_ID,
          mermaid: "sequenceDiagram\n User->>Gateway: Sign in\n Gateway->>API: Forward",
          expectedRevisionId: INITIAL_REVISION_ID,
          summary: "Show the gateway hop",
        },
      });
      assert.equal(proposed.isError, undefined);
      assert.equal(proposed.structuredContent.revisionId, NEXT_REVISION_ID);

      const state = await store.read();
      assert.equal(state.revisions.length, 2);
    });
  });

  it("lists and resolves app-authored review marks through MCP", async () => {
    await withMcpClient(async ({ client, store }) => {
      await client.callTool({
        name: "send_diagram",
        arguments: { title: "Review", mermaid: "flowchart LR\n Client --> API" },
      });
      await store.transaction((state) => {
        state.reviewMarks.push({
          id: "00000000-0000-4000-8000-000000000004",
          diagramId: DIAGRAM_ID,
          revisionId: INITIAL_REVISION_ID,
          type: "verify",
          symbol: "!",
          body: "Verify the API trust boundary",
          status: "open",
          anchor: {
            kind: "node",
            nodeID: "API",
            position: { x: 0.5, y: 0.5 },
          },
          createdAt: NOW,
          updatedAt: NOW,
          resolvedAt: null,
        });
      });

      const listed = await client.callTool({
        name: "list_review_marks",
        arguments: { diagramId: DIAGRAM_ID, status: "open", type: "verify" },
      });
      assert.equal(listed.structuredContent.count, 1);
      assert.equal(listed.structuredContent.marks[0].anchor.nodeID, "API");

      const resolved = await client.callTool({
        name: "resolve_review_mark",
        arguments: {
          diagramId: DIAGRAM_ID,
          markId: "00000000-0000-4000-8000-000000000004",
          expectedStatus: "open",
        },
      });
      assert.deepEqual(resolved.structuredContent, {
        diagramId: DIAGRAM_ID,
        markId: "00000000-0000-4000-8000-000000000004",
        status: "resolved",
      });
    });
  });

  it("returns stable, sanitized domain errors instead of crashing the server", async () => {
    await withMcpClient(async ({ client }) => {
      const invalid = await client.callTool({
        name: "send_diagram",
        arguments: { title: "Broken", mermaid: "flowchart LR\n A -->" },
      });

      assert.equal(invalid.isError, true);
      const payload = JSON.parse(invalid.content[0].text);
      assert.equal(payload.error.code, "INVALID_MERMAID");
      assert.equal(payload.error.message, "Mermaid source could not be parsed.");
      assert.equal("stack" in payload.error, false);

      const toolsAfterError = await client.listTools();
      assert.equal(toolsAfterError.tools.length, 4);
    });
  });

  it("sanitizes unexpected errors and reports them out of band", async () => {
    const unexpected = new Error("private path: /Users/example/secret.json");
    let reported;
    const server = createReviewCanvasMcpServer({
      service: {
        sendDiagram: async () => {
          throw unexpected;
        },
        listReviewMarks: async () => ({ count: 0, marks: [] }),
        proposeRevision: async () => ({}),
        resolveReviewMark: async () => ({}),
      },
      reportError: (error) => {
        reported = error;
      },
    });
    const client = new Client({ name: "unexpected-error-test", version: "1.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    await client.connect(clientTransport);

    try {
      const result = await client.callTool({
        name: "send_diagram",
        arguments: { title: "Valid", mermaid: "flowchart LR\n A --> B" },
      });
      const payload = JSON.parse(result.content[0].text);
      assert.equal(result.isError, true);
      assert.equal(payload.error.code, "INTERNAL_ERROR");
      assert.equal(payload.error.message.includes("/Users/example"), false);
      assert.equal(reported, unexpected);
    } finally {
      await client.close();
      await server.close();
    }
  });
});

describe("stdio entrypoint", () => {
  it("starts as a real MCP stdio server and writes to the configured data directory", async () => {
    await withTemporaryDirectory(async (directory) => {
      const transport = new StdioClientTransport({
        command: process.execPath,
        args: [path.join(MCP_ROOT, "bin", "review-canvas-mcp.js")],
        cwd: MCP_ROOT,
        env: { REVIEW_CANVAS_DATA_DIR: directory },
        stderr: "pipe",
      });
      const client = new Client({ name: "stdio-test", version: "1.0.0" });

      await client.connect(transport);
      try {
        const result = await client.callTool({
          name: "send_diagram",
          arguments: { title: "Stdio", mermaid: "flowchart LR\n A --> B" },
        });
        assert.equal(result.structuredContent.status, "queued");

        const store = new JsonStore(path.join(directory, "store.json"));
        const state = await store.read();
        assert.equal(state.inbox[0].title, "Stdio");
      } finally {
        await client.close();
      }
    });
  });
});
