import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { REVIEW_MARK_STATUSES, REVIEW_MARK_TYPES, TARGET_DEVICES } from "./constants.js";
import { ReviewCanvasError } from "./errors.js";

const uuid = z.string().uuid();
const mermaid = z.string().min(1);

const sendDiagramInput = z
  .object({
    title: z.string().min(1).max(200),
    mermaid,
    targetDevice: z.enum(TARGET_DEVICES).optional(),
  })
  .strict();
const sendDiagramOutput = z
  .object({
    diagramId: uuid,
    revisionId: uuid,
    status: z.literal("queued"),
  })
  .strict();

const listReviewMarksInput = z
  .object({
    diagramId: uuid.optional(),
    status: z.enum(REVIEW_MARK_STATUSES).optional(),
    type: z.enum(REVIEW_MARK_TYPES).optional(),
  })
  .strict();
const reviewMarkOutput = z
  .object({
    id: uuid,
    diagramId: uuid,
    revisionId: uuid,
    type: z.enum(REVIEW_MARK_TYPES),
    symbol: z.string().max(16),
    body: z.string().max(16_000),
    status: z.enum(REVIEW_MARK_STATUSES),
    createdAt: z.string(),
    updatedAt: z.string(),
    resolvedAt: z.string().nullable(),
    anchor: z
      .discriminatedUnion("kind", [
        z
          .object({
            kind: z.literal("node"),
            position: z
              .object({ x: z.number().min(0).max(1), y: z.number().min(0).max(1) })
              .strict(),
            nodeID: z.string().min(1).max(256),
          })
          .strict(),
        z
          .object({
            kind: z.literal("edge"),
            position: z
              .object({ x: z.number().min(0).max(1), y: z.number().min(0).max(1) })
              .strict(),
            edgeID: z.string().min(1).max(256),
          })
          .strict(),
        z
          .object({
            kind: z.literal("canvas"),
            position: z
              .object({ x: z.number().min(0).max(1), y: z.number().min(0).max(1) })
              .strict(),
          })
          .strict(),
      ])
      .optional(),
  })
  .strict();
const listReviewMarksOutput = z
  .object({
    count: z.number().int().nonnegative(),
    marks: z.array(reviewMarkOutput),
  })
  .strict();

const proposeRevisionInput = z
  .object({
    diagramId: uuid,
    mermaid,
    expectedRevisionId: uuid,
    summary: z.string().max(2_000).optional(),
  })
  .strict();
const proposeRevisionOutput = z
  .object({
    diagramId: uuid,
    revisionId: uuid,
    parentRevisionId: uuid,
    status: z.literal("proposed"),
  })
  .strict();

const resolveReviewMarkInput = z
  .object({
    diagramId: uuid,
    markId: uuid,
    expectedStatus: z.enum(REVIEW_MARK_STATUSES).optional(),
  })
  .strict();
const resolveReviewMarkOutput = z
  .object({
    diagramId: uuid,
    markId: uuid,
    status: z.literal("resolved"),
  })
  .strict();

function successResult(result) {
  return {
    content: [{ type: "text", text: JSON.stringify(result) }],
    structuredContent: result,
  };
}

function errorResult(error, reportError) {
  if (!(error instanceof ReviewCanvasError)) {
    reportError?.(error);
  }

  const payload = {
    error:
      error instanceof ReviewCanvasError
        ? {
            code: error.code,
            message: error.message,
            ...(error.details === undefined ? {} : { details: error.details }),
          }
        : {
            code: "INTERNAL_ERROR",
            message: "Review Canvas could not complete the request.",
          },
  };

  return {
    content: [{ type: "text", text: JSON.stringify(payload) }],
    isError: true,
  };
}

function toolHandler(operation, reportError) {
  return async (args) => {
    try {
      return successResult(await operation(args));
    } catch (error) {
      return errorResult(error, reportError);
    }
  };
}

export function createReviewCanvasMcpServer({ service, reportError } = {}) {
  if (!service) {
    throw new TypeError("service is required");
  }

  const server = new McpServer(
    { name: "review-canvas", version: "0.1.0" },
    {
      instructions:
        "Send Mermaid diagrams to the local Review Canvas inbox and respond to human review marks. Revisions are proposals and never overwrite the original source.",
    },
  );

  server.registerTool(
    "send_diagram",
    {
      title: "Send diagram",
      description: "Validate and queue a Mermaid diagram in the local Review Canvas inbox.",
      inputSchema: sendDiagramInput,
      outputSchema: sendDiagramOutput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    toolHandler((args) => service.sendDiagram(args), reportError),
  );

  server.registerTool(
    "list_review_marks",
    {
      title: "List review marks",
      description: "List local Review Canvas marks, optionally filtered by diagram, status, or type.",
      inputSchema: listReviewMarksInput,
      outputSchema: listReviewMarksOutput,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    toolHandler((args) => service.listReviewMarks(args), reportError),
  );

  server.registerTool(
    "propose_revision",
    {
      title: "Propose revision",
      description:
        "Create a new Mermaid revision from the expected head revision without overwriting existing source.",
      inputSchema: proposeRevisionInput,
      outputSchema: proposeRevisionOutput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    toolHandler((args) => service.proposeRevision(args), reportError),
  );

  server.registerTool(
    "resolve_review_mark",
    {
      title: "Resolve review mark",
      description: "Mark a local Review Canvas annotation as resolved with optional status checking.",
      inputSchema: resolveReviewMarkInput,
      outputSchema: resolveReviewMarkOutput,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    toolHandler((args) => service.resolveReviewMark(args), reportError),
  );

  return server;
}
