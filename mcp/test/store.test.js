import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  lstat,
  readFile,
  readdir,
  stat,
  symlink,
  truncate,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";

import { JsonStore, MAX_STORE_BYTES, defaultStorePath } from "../src/index.js";
import { withTemporaryDirectory } from "./helpers.js";

const NOW = "2026-08-05T01:23:45.000Z";
const execFileAsync = promisify(execFile);
const STORE_WORKER_PATH = fileURLToPath(
  new URL("../test-fixtures/store-worker.js", import.meta.url),
);

describe("JsonStore", () => {
  it("requires an absolute store path and a transaction function", async () => {
    assert.throws(() => new JsonStore("../store.json"), { code: "STORE_UNSAFE_PATH" });
    await withTemporaryDirectory(async (directory) => {
      const store = new JsonStore(path.join(directory, "store.json"));
      await assert.rejects(store.transaction(null), { name: "TypeError" });
    });
  });

  it("initializes an empty versioned store with ISO timestamps", async () => {
    await withTemporaryDirectory(async (directory) => {
      const storePath = path.join(directory, "nested", "store.json");
      const store = new JsonStore(storePath, { now: () => NOW });

      const state = await store.read();

      assert.deepEqual(state, {
        schemaVersion: 1,
        createdAt: NOW,
        updatedAt: NOW,
        inbox: [],
        diagrams: [],
        revisions: [],
        reviewMarks: [],
      });
      await assert.rejects(stat(storePath), { code: "ENOENT" });
    });
  });

  it("serializes concurrent transactions and writes owner-only JSON atomically", async () => {
    await withTemporaryDirectory(async (directory) => {
      const storePath = path.join(directory, "data", "store.json");
      const store = new JsonStore(storePath, { now: () => NOW });

      await Promise.all(
        Array.from({ length: 12 }, (_, index) =>
          store.transaction(async (state) => {
            await Promise.resolve();
            state.inbox.push({
              schemaVersion: 1,
              diagramId: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
              title: `Diagram ${index}`,
              targetDevice: "any",
              createdAt: NOW,
              revision: {
                id: `10000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
                parentRevisionId: null,
                sequence: 1,
                status: "current",
                source: "flowchart LR\n A --> B",
              },
            });
          }),
        ),
      );

      const persisted = JSON.parse(await readFile(storePath, "utf8"));
      assert.equal(persisted.inbox.length, 12);
      assert.equal((await stat(storePath)).mode & 0o777, 0o600);
      assert.deepEqual(
        (await readdir(path.dirname(storePath))).filter((name) => name.endsWith(".tmp")),
        [],
      );
    });
  });

  it("serializes transactions across independent store instances", async () => {
    await withTemporaryDirectory(async (directory) => {
      const storePath = path.join(directory, "store.json");
      const first = new JsonStore(storePath, { now: () => NOW });
      const second = new JsonStore(storePath, { now: () => NOW });

      await Promise.all(
        [first, second].map((store) =>
          store.transaction(async (state) => {
            const current = state.transactionCount ?? 0;
            await new Promise((resolve) => setTimeout(resolve, 30));
            state.transactionCount = current + 1;
          }),
        ),
      );

      assert.equal((await first.read()).transactionCount, 2);
    });
  });

  it("prevents lost updates across separate Node processes", async () => {
    await withTemporaryDirectory(async (directory) => {
      const storePath = path.join(directory, "store.json");

      await Promise.all([
        execFileAsync(process.execPath, [STORE_WORKER_PATH, storePath]),
        execFileAsync(process.execPath, [STORE_WORKER_PATH, storePath]),
      ]);

      const store = new JsonStore(storePath);
      assert.equal((await store.read()).processTransactionCount, 2);
    });
  });

  it("does not overwrite corrupt or unsupported stores", async () => {
    await withTemporaryDirectory(async (directory) => {
      const invalidJsonPath = path.join(directory, "invalid.json");
      await writeFile(invalidJsonPath, "{nope", "utf8");
      const invalidJsonStore = new JsonStore(invalidJsonPath, { now: () => NOW });
      await assert.rejects(invalidJsonStore.read(), { code: "STORE_CORRUPT" });
      assert.equal(await readFile(invalidJsonPath, "utf8"), "{nope");

      const futurePath = path.join(directory, "future.json");
      await writeFile(
        futurePath,
        JSON.stringify({
          schemaVersion: 999,
          createdAt: NOW,
          updatedAt: NOW,
          inbox: [],
          diagrams: [],
          revisions: [],
          reviewMarks: [],
        }),
      );
      const futureStore = new JsonStore(futurePath, { now: () => NOW });
      await assert.rejects(futureStore.read(), { code: "STORE_VERSION_UNSUPPORTED" });
    });
  });

  it("rejects persisted stores larger than the configured safety limit", async () => {
    await withTemporaryDirectory(async (directory) => {
      const storePath = path.join(directory, "huge.json");
      await writeFile(storePath, "{}");
      await truncate(storePath, MAX_STORE_BYTES + 1);

      const store = new JsonStore(storePath, { now: () => NOW });
      await assert.rejects(store.read(), { code: "STORE_TOO_LARGE" });
    });
  });

  it("refuses to read through symbolic links", async () => {
    await withTemporaryDirectory(async (directory) => {
      const outsidePath = path.join(directory, "outside.json");
      const linkPath = path.join(directory, "store.json");
      await writeFile(outsidePath, '{"secret":true}');
      await symlink(outsidePath, linkPath);

      const store = new JsonStore(linkPath, { now: () => NOW });
      await assert.rejects(store.read(), { code: "STORE_UNSAFE_PATH" });
      assert.equal((await lstat(linkPath)).isSymbolicLink(), true);
    });
  });

  it("refuses traversal-like and duplicate inbox envelope names", async () => {
    await withTemporaryDirectory(async (directory) => {
      const store = new JsonStore(path.join(directory, "store.json"), { now: () => NOW });
      const envelope = {
        schemaVersion: 1,
        diagramId: "00000000-0000-4000-8000-000000000001",
        title: "Safe",
        targetDevice: "any",
        createdAt: NOW,
        revision: {
          id: "00000000-0000-4000-8000-000000000002",
          parentRevisionId: null,
          sequence: 1,
          status: "current",
          source: "flowchart LR\n A --> B",
        },
      };
      await store.writeInboxEnvelope(envelope);
      await assert.rejects(store.writeInboxEnvelope(envelope), {
        code: "INBOX_ENVELOPE_EXISTS",
      });
      await assert.rejects(
        store.writeInboxEnvelope({ ...envelope, diagramId: "../../outside" }),
        { code: "INVALID_ID" },
      );
    });
  });

  it("rejects review mark anchors that do not match the app contract", async () => {
    await withTemporaryDirectory(async (directory) => {
      const store = new JsonStore(path.join(directory, "store.json"), { now: () => NOW });

      await assert.rejects(
        store.transaction((state) => {
          state.reviewMarks.push({
            id: "00000000-0000-4000-8000-000000000004",
            diagramId: "00000000-0000-4000-8000-000000000001",
            revisionId: "00000000-0000-4000-8000-000000000002",
            type: "verify",
            symbol: "!",
            body: "Verify the boundary",
            status: "open",
            anchor: {
              kind: "node",
              nodeID: "API",
              position: { x: 0.5, y: 0.5 },
              injected: "not part of the schema",
            },
            createdAt: NOW,
            updatedAt: NOW,
            resolvedAt: null,
          });
        }),
        { code: "STORE_CORRUPT" },
      );
    });
  });

  it("recovers only a prepared envelope left by an interrupted queued write", async () => {
    await withTemporaryDirectory(async (directory) => {
      const store = new JsonStore(path.join(directory, "store.json"), { now: () => NOW });
      const diagramId = "00000000-0000-4000-8000-000000000001";
      const revisionId = "00000000-0000-4000-8000-000000000002";
      const envelope = {
        schemaVersion: 1,
        diagramId,
        title: "Interrupted",
        targetDevice: "any",
        createdAt: NOW,
        revision: {
          id: revisionId,
          parentRevisionId: null,
          sequence: 1,
          status: "current",
          source: "flowchart LR\n A --> B",
        },
      };
      await store.transaction((state) => {
        state.inbox.push(envelope);
        state.diagrams.push({
          id: diagramId,
          title: envelope.title,
          targetDevice: "any",
          status: "queued",
          currentRevisionId: revisionId,
          headRevisionId: revisionId,
          createdAt: NOW,
          updatedAt: NOW,
        });
        state.revisions.push({
          id: revisionId,
          diagramId,
          parentRevisionId: null,
          sequence: 1,
          source: envelope.revision.source,
          summary: null,
          status: "current",
          createdAt: NOW,
        });
      });

      const recoveryToken = "10000000-0000-4000-8000-000000000099";
      const preparedPath = path.join(
        directory,
        `.diagram-${diagramId}.${recoveryToken}.tmp`,
      );
      const unrelatedPath = path.join(
        directory,
        ".diagram-00000000-0000-4000-8000-000000000098.10000000-0000-4000-8000-000000000098.tmp",
      );
      await writeFile(preparedPath, `${JSON.stringify(envelope, null, 2)}\n`, "utf8");
      await writeFile(unrelatedPath, "orphaned preparation", "utf8");

      const result = await store.recoverInterruptedQueues();

      assert.deepEqual(result, { recovered: 1, discarded: 1 });
      assert.deepEqual(
        JSON.parse(await readFile(path.join(directory, `diagram-${diagramId}.json`), "utf8")),
        envelope,
      );
      await assert.rejects(stat(preparedPath), { code: "ENOENT" });
      await assert.rejects(stat(unrelatedPath), { code: "ENOENT" });
    });
  });
});

describe("defaultStorePath", () => {
  it("uses the macOS Review Canvas Inbox directory", () => {
    assert.equal(
      defaultStorePath({ env: {}, platform: "darwin", homeDirectory: "/Users/test" }),
      "/Users/test/Library/Application Support/Review Canvas/Inbox/store.json",
    );
  });

  it("uses an absolute data-directory override and rejects relative traversal", () => {
    assert.equal(
      defaultStorePath({
        env: { REVIEW_CANVAS_DATA_DIR: "/tmp/review-canvas-inbox" },
        platform: "darwin",
        homeDirectory: "/Users/test",
      }),
      "/tmp/review-canvas-inbox/store.json",
    );
    assert.throws(
      () =>
        defaultStorePath({
          env: { REVIEW_CANVAS_DATA_DIR: "../outside" },
          platform: "darwin",
          homeDirectory: "/Users/test",
        }),
      { code: "STORE_UNSAFE_PATH" },
    );
  });

  it("builds platform-appropriate non-macOS data paths", () => {
    assert.equal(
      defaultStorePath({
        env: { LOCALAPPDATA: "C:\\Data" },
        platform: "win32",
        homeDirectory: "C:\\Users\\test",
      }),
      path.join("C:\\Data", "Review Canvas", "Inbox", "store.json"),
    );
    assert.equal(
      defaultStorePath({
        env: { XDG_DATA_HOME: "/var/data" },
        platform: "linux",
        homeDirectory: "/home/test",
      }),
      "/var/data/review-canvas/Inbox/store.json",
    );
  });
});
