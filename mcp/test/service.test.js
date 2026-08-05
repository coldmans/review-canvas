import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

import {
  JsonStore,
  MAX_MERMAID_BYTES,
  ReviewCanvasService,
} from "../src/index.js";
import {
  DIAGRAM_ID,
  INITIAL_REVISION_ID,
  MARK_ID,
  NEXT_REVISION_ID,
  sequenceIdGenerator,
  withTemporaryDirectory,
} from "./helpers.js";

const NOW = "2026-08-05T01:23:45.000Z";
const LATER = "2026-08-05T02:34:56.000Z";

async function withService(run, options = {}) {
  return withTemporaryDirectory(async (directory) => {
    const clockValues = options.clockValues ?? [NOW];
    let clockIndex = 0;
    const serviceNow = () => clockValues[Math.min(clockIndex++, clockValues.length - 1)];
    const store = new JsonStore(path.join(directory, "store.json"), { now: () => NOW });
    const service = new ReviewCanvasService({
      store,
      now: serviceNow,
      idGenerator: sequenceIdGenerator(
        options.ids ?? [DIAGRAM_ID, INITIAL_REVISION_ID, NEXT_REVISION_ID],
      ),
    });

    await run({ service, store, directory });
  });
}

describe("ReviewCanvasService.sendDiagram", () => {
  it("requires a store and rejects non-object arguments", async () => {
    assert.throws(() => new ReviewCanvasService({}), { name: "TypeError" });

    await withService(async ({ service }) => {
      await assert.rejects(service.sendDiagram(null), { code: "INVALID_ARGUMENT" });
      await assert.rejects(
        service.sendDiagram({ title: 42, mermaid: "flowchart LR\n A --> B" }),
        { code: "INVALID_ARGUMENT" },
      );
      await assert.rejects(
        service.sendDiagram({ title: " ", mermaid: "flowchart LR\n A --> B" }),
        { code: "INVALID_ARGUMENT" },
      );
    });
  });

  it("queues a valid diagram and its immutable initial revision", async () => {
    await withService(async ({ service, store, directory }) => {
      const result = await service.sendDiagram({
        title: "Checkout architecture",
        mermaid: "flowchart LR\n  Client --> API",
        targetDevice: "ipad",
      });

      assert.deepEqual(result, {
        diagramId: DIAGRAM_ID,
        revisionId: INITIAL_REVISION_ID,
        status: "queued",
      });

      const state = await store.read();
      assert.equal(state.schemaVersion, 1);
      assert.deepEqual(state.inbox, [
        {
          schemaVersion: 1,
          diagramId: DIAGRAM_ID,
          title: "Checkout architecture",
          targetDevice: "ipad",
          createdAt: NOW,
          revision: {
            id: INITIAL_REVISION_ID,
            parentRevisionId: null,
            sequence: 1,
            status: "current",
            source: "flowchart LR\n  Client --> API",
          },
        },
      ]);
      assert.deepEqual(state.diagrams, [
        {
          id: DIAGRAM_ID,
          title: "Checkout architecture",
          targetDevice: "ipad",
          status: "queued",
          currentRevisionId: INITIAL_REVISION_ID,
          headRevisionId: INITIAL_REVISION_ID,
          createdAt: NOW,
          updatedAt: NOW,
        },
      ]);
      assert.equal(state.revisions[0].source, "flowchart LR\n  Client --> API");
      assert.equal(state.revisions[0].parentRevisionId, null);
      assert.equal(state.revisions[0].sequence, 1);
      assert.equal(state.revisions[0].status, "current");

      const envelope = JSON.parse(
        await readFile(path.join(directory, `diagram-${DIAGRAM_ID}.json`), "utf8"),
      );
      assert.deepEqual(envelope, state.inbox[0]);
    });
  });

  it("defaults targetDevice to any", async () => {
    await withService(async ({ service, store }) => {
      await service.sendDiagram({ title: "Diagram", mermaid: "graph TD\n A --> B" });

      const state = await store.read();
      assert.equal(state.diagrams[0].targetDevice, "any");
    });
  });

  it("rejects unsupported, malformed, empty, and oversized Mermaid", async () => {
    await withService(async ({ service }) => {
      await assert.rejects(
        service.sendDiagram({ title: "No", mermaid: "not-a-diagram" }),
        { code: "INVALID_MERMAID" },
      );
      await assert.rejects(
        service.sendDiagram({ title: "Broken", mermaid: "flowchart LR\n A -->" }),
        { code: "INVALID_MERMAID" },
      );
      await assert.rejects(
        service.sendDiagram({ title: "Empty", mermaid: "   \n" }),
        { code: "INVALID_MERMAID" },
      );
      await assert.rejects(
        service.sendDiagram({
          title: "Too large",
          mermaid: `flowchart LR\n%%${"x".repeat(MAX_MERMAID_BYTES)}`,
        }),
        { code: "DIAGRAM_TOO_LARGE" },
      );
    });
  });

  it("rejects invalid fields without creating a store entry", async () => {
    await withService(async ({ service, store }) => {
      await assert.rejects(
        service.sendDiagram({
          title: "../escape",
          mermaid: "flowchart LR\n A --> B",
          targetDevice: "watch",
        }),
        { code: "INVALID_ARGUMENT" },
      );

      const state = await store.read();
      assert.equal(state.diagrams.length, 0);
    });
  });

  it("rejects generated diagram and revision ID collisions", async () => {
    await withService(async ({ service, store }) => {
      await service.sendDiagram({ title: "First", mermaid: "flowchart LR\n A --> B" });

      const duplicateDiagram = new ReviewCanvasService({
        store,
        now: () => NOW,
        idGenerator: sequenceIdGenerator([DIAGRAM_ID, NEXT_REVISION_ID]),
      });
      await assert.rejects(
        duplicateDiagram.sendDiagram({ title: "Duplicate", mermaid: "flowchart LR\n B --> C" }),
        { code: "ID_CONFLICT" },
      );

      const duplicateRevision = new ReviewCanvasService({
        store,
        now: () => NOW,
        idGenerator: sequenceIdGenerator([
          "00000000-0000-4000-8000-000000000099",
          INITIAL_REVISION_ID,
        ]),
      });
      await assert.rejects(
        duplicateRevision.sendDiagram({ title: "Duplicate", mermaid: "flowchart LR\n B --> C" }),
        { code: "ID_CONFLICT" },
      );
    });
  });

  it("does not commit a diagram when its envelope filename is already occupied", async () => {
    await withService(async ({ service, store, directory }) => {
      const envelopePath = path.join(directory, `diagram-${DIAGRAM_ID}.json`);
      await writeFile(envelopePath, "occupied", "utf8");

      await assert.rejects(
        service.sendDiagram({ title: "Collision", mermaid: "flowchart LR\n A --> B" }),
        { code: "INBOX_ENVELOPE_EXISTS" },
      );

      const state = await store.read();
      assert.equal(state.inbox.length, 0);
      assert.equal(state.diagrams.length, 0);
      assert.equal(state.revisions.length, 0);
      assert.equal(await readFile(envelopePath, "utf8"), "occupied");
    });
  });
});

describe("ReviewCanvasService revisions", () => {
  it("creates a new revision without overwriting the original", async () => {
    await withService(
      async ({ service, store }) => {
        await service.sendDiagram({
          title: "Architecture",
          mermaid: "flowchart LR\n A --> B",
        });

        const result = await service.proposeRevision({
          diagramId: DIAGRAM_ID,
          mermaid: "flowchart LR\n A --> Gateway --> B",
          expectedRevisionId: INITIAL_REVISION_ID,
          summary: "Add the gateway boundary",
        });

        assert.deepEqual(result, {
          diagramId: DIAGRAM_ID,
          revisionId: NEXT_REVISION_ID,
          parentRevisionId: INITIAL_REVISION_ID,
          status: "proposed",
        });

        const state = await store.read();
        assert.equal(state.revisions.length, 2);
        assert.equal(state.revisions[0].source, "flowchart LR\n A --> B");
        assert.equal(state.revisions[1].parentRevisionId, INITIAL_REVISION_ID);
        assert.equal(state.revisions[1].sequence, 2);
        assert.equal(state.revisions[1].status, "proposed");
        assert.equal(state.diagrams[0].currentRevisionId, INITIAL_REVISION_ID);
        assert.equal(state.diagrams[0].headRevisionId, NEXT_REVISION_ID);
        assert.equal(state.diagrams[0].updatedAt, LATER);
      },
      { clockValues: [NOW, LATER] },
    );
  });

  it("rejects stale revisions, unknown diagrams, traversal-like IDs, and invalid Mermaid", async () => {
    await withService(async ({ service }) => {
      await service.sendDiagram({
        title: "Architecture",
        mermaid: "flowchart LR\n A --> B",
      });

      await assert.rejects(
        service.proposeRevision({
          diagramId: DIAGRAM_ID,
          mermaid: "flowchart LR\n A --> C",
          expectedRevisionId: NEXT_REVISION_ID,
        }),
        { code: "REVISION_CONFLICT" },
      );
      await assert.rejects(
        service.proposeRevision({
          diagramId: "../store.json",
          mermaid: "flowchart LR\n A --> C",
          expectedRevisionId: INITIAL_REVISION_ID,
        }),
        { code: "INVALID_ID" },
      );
      await assert.rejects(
        service.proposeRevision({
          diagramId: "00000000-0000-4000-8000-000000000099",
          mermaid: "flowchart LR\n A --> C",
          expectedRevisionId: INITIAL_REVISION_ID,
        }),
        { code: "DIAGRAM_NOT_FOUND" },
      );
      await assert.rejects(
        service.proposeRevision({
          diagramId: DIAGRAM_ID,
          mermaid: "flowchart LR\n A -->",
          expectedRevisionId: INITIAL_REVISION_ID,
        }),
        { code: "INVALID_MERMAID" },
      );
    });
  });

  it("rejects missing parents, generated ID collisions, and invalid summaries", async () => {
    await withService(async ({ service, store }) => {
      await service.sendDiagram({ title: "Architecture", mermaid: "flowchart LR\n A --> B" });

      await assert.rejects(
        service.proposeRevision({
          diagramId: DIAGRAM_ID,
          mermaid: "flowchart LR\n A --> C",
          expectedRevisionId: INITIAL_REVISION_ID,
          summary: "x".repeat(2_001),
        }),
        { code: "INVALID_ARGUMENT" },
      );

      const duplicateRevisionService = new ReviewCanvasService({
        store,
        now: () => NOW,
        idGenerator: () => INITIAL_REVISION_ID,
      });
      await assert.rejects(
        duplicateRevisionService.proposeRevision({
          diagramId: DIAGRAM_ID,
          mermaid: "flowchart LR\n A --> C",
          expectedRevisionId: INITIAL_REVISION_ID,
        }),
        { code: "ID_CONFLICT" },
      );

      const missingRevisionId = "00000000-0000-4000-8000-000000000098";
      await store.transaction((state) => {
        state.diagrams[0].headRevisionId = missingRevisionId;
      });
      await assert.rejects(
        service.proposeRevision({
          diagramId: DIAGRAM_ID,
          mermaid: "flowchart LR\n A --> C",
          expectedRevisionId: missingRevisionId,
        }),
        { code: "REVISION_NOT_FOUND" },
      );
    });
  });
});

describe("ReviewCanvasService review marks", () => {
  it("lists marks using diagram, status, and type filters", async () => {
    await withService(async ({ service, store }) => {
      await service.sendDiagram({ title: "One", mermaid: "flowchart LR\n A --> B" });
      await store.transaction((state) => {
        state.reviewMarks.push(
          {
            id: MARK_ID,
            diagramId: DIAGRAM_ID,
            revisionId: INITIAL_REVISION_ID,
            type: "explain",
            symbol: "?",
            body: "Why is this dependency needed?",
            status: "open",
            createdAt: NOW,
            updatedAt: NOW,
            resolvedAt: null,
            privateAppState: "must not cross the MCP boundary",
          },
          {
            id: "00000000-0000-4000-8000-000000000005",
            diagramId: DIAGRAM_ID,
            revisionId: INITIAL_REVISION_ID,
            type: "verify",
            symbol: "!",
            body: "Check this boundary",
            status: "resolved",
            createdAt: NOW,
            updatedAt: NOW,
            resolvedAt: NOW,
          },
        );
      });

      const result = await service.listReviewMarks({
        diagramId: DIAGRAM_ID,
        status: "open",
        type: "explain",
      });

      assert.equal(result.count, 1);
      assert.deepEqual(result.marks, [
        {
          id: MARK_ID,
          diagramId: DIAGRAM_ID,
          revisionId: INITIAL_REVISION_ID,
          type: "explain",
          symbol: "?",
          body: "Why is this dependency needed?",
          status: "open",
          createdAt: NOW,
          updatedAt: NOW,
          resolvedAt: null,
        },
      ]);
      assert.equal("privateAppState" in result.marks[0], false);
    });
  });

  it("rejects unknown filters and path-like IDs", async () => {
    await withService(async ({ service }) => {
      await assert.rejects(service.listReviewMarks({ status: "pending" }), {
        code: "INVALID_STATUS",
      });
      await assert.rejects(service.listReviewMarks({ type: "delete" }), {
        code: "INVALID_TYPE",
      });
      await assert.rejects(service.listReviewMarks({ diagramId: "../../outside" }), {
        code: "INVALID_ID",
      });
    });
  });

  it("resolves an open mark and honors expectedStatus", async () => {
    await withService(
      async ({ service, store }) => {
        await service.sendDiagram({ title: "One", mermaid: "flowchart LR\n A --> B" });
        await store.transaction((state) => {
          state.reviewMarks.push({
            id: MARK_ID,
            diagramId: DIAGRAM_ID,
            revisionId: INITIAL_REVISION_ID,
            type: "change",
            symbol: "✎",
            body: "Split this node",
            status: "open",
            createdAt: NOW,
            updatedAt: NOW,
            resolvedAt: null,
          });
        });

        const result = await service.resolveReviewMark({
          diagramId: DIAGRAM_ID,
          markId: MARK_ID,
          expectedStatus: "open",
        });

        assert.deepEqual(result, {
          diagramId: DIAGRAM_ID,
          markId: MARK_ID,
          status: "resolved",
        });
        const state = await store.read();
        assert.equal(state.reviewMarks[0].resolvedAt, LATER);

        await assert.rejects(
          service.resolveReviewMark({
            diagramId: DIAGRAM_ID,
            markId: MARK_ID,
            expectedStatus: "open",
          }),
          { code: "MARK_STATUS_CONFLICT" },
        );
      },
      { clockValues: [NOW, LATER] },
    );
  });

  it("rejects unknown marks, mismatched diagrams, invalid statuses, and traversal-like IDs", async () => {
    await withService(async ({ service, store }) => {
      await service.sendDiagram({ title: "One", mermaid: "flowchart LR\n A --> B" });
      await store.transaction((state) => {
        state.reviewMarks.push({
          id: MARK_ID,
          diagramId: "00000000-0000-4000-8000-000000000099",
          revisionId: INITIAL_REVISION_ID,
          type: "verify",
          symbol: "!",
          body: "Check this",
          status: "open",
          createdAt: NOW,
          updatedAt: NOW,
          resolvedAt: null,
        });
      });

      await assert.rejects(
        service.resolveReviewMark({ diagramId: DIAGRAM_ID, markId: MARK_ID }),
        { code: "MARK_DIAGRAM_MISMATCH" },
      );
      await assert.rejects(
        service.resolveReviewMark({
          diagramId: DIAGRAM_ID,
          markId: "00000000-0000-4000-8000-000000000098",
        }),
        { code: "MARK_NOT_FOUND" },
      );
      await assert.rejects(
        service.resolveReviewMark({
          diagramId: DIAGRAM_ID,
          markId: "../mark.json",
        }),
        { code: "INVALID_ID" },
      );
      await assert.rejects(
        service.resolveReviewMark({
          diagramId: DIAGRAM_ID,
          markId: MARK_ID,
          expectedStatus: "pending",
        }),
        { code: "INVALID_STATUS" },
      );
    });
  });
});
