import { constants as fileConstants } from "node:fs";
import { lstat, mkdir, open, readFile, readdir, rename, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { Buffer } from "node:buffer";

import {
  MAX_COLLECTION_ITEMS,
  MAX_MERMAID_BYTES,
  MAX_REVIEW_MARK_ANCHOR_BYTES,
  MAX_REVIEW_MARK_BODY_LENGTH,
  MAX_REVIEW_MARK_SYMBOL_LENGTH,
  MAX_STORE_BYTES,
  REVIEW_MARK_STATUSES,
  REVIEW_MARK_TYPES,
  REVISION_STATUSES,
  STORE_SCHEMA_VERSION,
  TARGET_DEVICES,
} from "./constants.js";
import { ReviewCanvasError, fail } from "./errors.js";

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isIsoTimestamp(value) {
  return typeof value === "string" && new Date(value).toISOString() === value;
}

function assertIsoTimestamp(value, field) {
  try {
    if (isIsoTimestamp(value)) {
      return;
    }
  } catch {
    // Fall through to the stable store error below.
  }
  fail("STORE_CORRUPT", `Store field ${field} must be an ISO timestamp.`);
}

const LOCK_ACQUIRE_TIMEOUT_MS = 5_000;
const LOCK_STALE_AFTER_MS = 120_000;

function assertString(
  value,
  field,
  { nullable = false, minimumLength, maximumLength, maximumBytes } = {},
) {
  if ((nullable && value === null) || typeof value === "string") {
    if (
      value === null ||
      ((minimumLength === undefined || value.length >= minimumLength) &&
        (maximumLength === undefined || value.length <= maximumLength) &&
        (maximumBytes === undefined || Buffer.byteLength(value, "utf8") <= maximumBytes))
    ) {
      return;
    }
  }
  fail("STORE_CORRUPT", `Store field ${field} is invalid or too large.`);
}

function hasExactKeys(value, expectedKeys) {
  const actualKeys = Object.keys(value);
  return (
    actualKeys.length === expectedKeys.length &&
    expectedKeys.every((key) => Object.hasOwn(value, key))
  );
}

function assertNormalizedPosition(value, field) {
  if (
    !isPlainObject(value) ||
    !hasExactKeys(value, ["x", "y"]) ||
    !Number.isFinite(value.x) ||
    !Number.isFinite(value.y) ||
    value.x < 0 ||
    value.x > 1 ||
    value.y < 0 ||
    value.y > 1
  ) {
    fail("STORE_CORRUPT", `Store field ${field} must be a normalized position.`);
  }
}

function assertAnchor(anchor, field) {
  if (!isPlainObject(anchor)) {
    fail("STORE_CORRUPT", `Store field ${field} must be an anchor object.`);
  }
  if (Buffer.byteLength(JSON.stringify(anchor), "utf8") > MAX_REVIEW_MARK_ANCHOR_BYTES) {
    fail("STORE_CORRUPT", `Store field ${field} is too large.`);
  }

  if (anchor.kind === "node") {
    if (!hasExactKeys(anchor, ["kind", "position", "nodeID"])) {
      fail("STORE_CORRUPT", `Store field ${field} has invalid node anchor keys.`);
    }
    assertString(anchor.nodeID, `${field}.nodeID`, { minimumLength: 1, maximumLength: 256 });
  } else if (anchor.kind === "edge") {
    if (!hasExactKeys(anchor, ["kind", "position", "edgeID"])) {
      fail("STORE_CORRUPT", `Store field ${field} has invalid edge anchor keys.`);
    }
    assertString(anchor.edgeID, `${field}.edgeID`, { minimumLength: 1, maximumLength: 256 });
  } else if (anchor.kind === "canvas") {
    if (!hasExactKeys(anchor, ["kind", "position"])) {
      fail("STORE_CORRUPT", `Store field ${field} has invalid canvas anchor keys.`);
    }
  } else {
    fail("STORE_CORRUPT", `Store field ${field}.kind is invalid.`);
  }

  assertNormalizedPosition(anchor.position, `${field}.position`);
}

function isProcessAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    return undefined;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function assertEnvelope(envelope, index) {
  if (!isPlainObject(envelope) || envelope.schemaVersion !== STORE_SCHEMA_VERSION) {
    fail("STORE_CORRUPT", `inbox[${index}] is not a supported envelope.`);
  }
  assertString(envelope.diagramId, `inbox[${index}].diagramId`);
  assertString(envelope.title, `inbox[${index}].title`, { maximumLength: 200 });
  if (envelope.targetDevice !== undefined && !TARGET_DEVICES.includes(envelope.targetDevice)) {
    fail("STORE_CORRUPT", `inbox[${index}].targetDevice is invalid.`);
  }
  assertIsoTimestamp(envelope.createdAt, `inbox[${index}].createdAt`);

  const revision = envelope.revision;
  if (!isPlainObject(revision)) {
    fail("STORE_CORRUPT", `inbox[${index}].revision must be an object.`);
  }
  assertString(revision.id, `inbox[${index}].revision.id`);
  assertString(revision.parentRevisionId, `inbox[${index}].revision.parentRevisionId`, {
    nullable: true,
  });
  if (revision.sequence !== 1 || revision.status !== "current") {
    fail("STORE_CORRUPT", `inbox[${index}].revision must be the initial current revision.`);
  }
  assertString(revision.source, `inbox[${index}].revision.source`, {
    maximumBytes: MAX_MERMAID_BYTES,
  });
}

function assertDiagram(diagram, index) {
  if (!isPlainObject(diagram)) {
    fail("STORE_CORRUPT", `diagrams[${index}] must be an object.`);
  }
  for (const field of ["id", "status", "currentRevisionId", "headRevisionId"]) {
    assertString(diagram[field], `diagrams[${index}].${field}`);
  }
  assertString(diagram.title, `diagrams[${index}].title`, { maximumLength: 200 });
  if (!TARGET_DEVICES.includes(diagram.targetDevice)) {
    fail("STORE_CORRUPT", `diagrams[${index}].targetDevice is invalid.`);
  }
  assertIsoTimestamp(diagram.createdAt, `diagrams[${index}].createdAt`);
  assertIsoTimestamp(diagram.updatedAt, `diagrams[${index}].updatedAt`);
}

function assertRevision(revision, index) {
  if (!isPlainObject(revision)) {
    fail("STORE_CORRUPT", `revisions[${index}] must be an object.`);
  }
  for (const field of ["id", "diagramId"]) {
    assertString(revision[field], `revisions[${index}].${field}`);
  }
  assertString(revision.source, `revisions[${index}].source`, {
    maximumBytes: MAX_MERMAID_BYTES,
  });
  assertString(revision.parentRevisionId, `revisions[${index}].parentRevisionId`, {
    nullable: true,
  });
  if (!Number.isSafeInteger(revision.sequence) || revision.sequence < 1) {
    fail("STORE_CORRUPT", `revisions[${index}].sequence is invalid.`);
  }
  if (!REVISION_STATUSES.includes(revision.status)) {
    fail("STORE_CORRUPT", `revisions[${index}].status is invalid.`);
  }
  assertString(revision.summary, `revisions[${index}].summary`, {
    nullable: true,
    maximumLength: 2_000,
  });
  assertIsoTimestamp(revision.createdAt, `revisions[${index}].createdAt`);
}

function assertReviewMark(mark, index) {
  if (!isPlainObject(mark)) {
    fail("STORE_CORRUPT", `reviewMarks[${index}] must be an object.`);
  }
  for (const field of ["id", "diagramId", "revisionId"]) {
    assertString(mark[field], `reviewMarks[${index}].${field}`);
  }
  assertString(mark.symbol, `reviewMarks[${index}].symbol`, {
    maximumLength: MAX_REVIEW_MARK_SYMBOL_LENGTH,
  });
  assertString(mark.body, `reviewMarks[${index}].body`, {
    maximumLength: MAX_REVIEW_MARK_BODY_LENGTH,
  });
  if (!REVIEW_MARK_TYPES.includes(mark.type)) {
    fail("STORE_CORRUPT", `reviewMarks[${index}].type is invalid.`);
  }
  if (!REVIEW_MARK_STATUSES.includes(mark.status)) {
    fail("STORE_CORRUPT", `reviewMarks[${index}].status is invalid.`);
  }
  assertIsoTimestamp(mark.createdAt, `reviewMarks[${index}].createdAt`);
  assertIsoTimestamp(mark.updatedAt, `reviewMarks[${index}].updatedAt`);
  if (mark.resolvedAt !== null) {
    assertIsoTimestamp(mark.resolvedAt, `reviewMarks[${index}].resolvedAt`);
  }
  if (mark.anchor !== undefined) {
    assertAnchor(mark.anchor, `reviewMarks[${index}].anchor`);
  }
}

function validateStoreState(state) {
  if (!isPlainObject(state)) {
    fail("STORE_CORRUPT", "Store root must be an object.");
  }
  if (state.schemaVersion !== STORE_SCHEMA_VERSION) {
    fail(
      "STORE_VERSION_UNSUPPORTED",
      `Store schema ${String(state.schemaVersion)} is not supported.`,
      { supportedVersion: STORE_SCHEMA_VERSION },
    );
  }
  assertIsoTimestamp(state.createdAt, "createdAt");
  assertIsoTimestamp(state.updatedAt, "updatedAt");

  for (const collection of ["inbox", "diagrams", "revisions", "reviewMarks"]) {
    if (!Array.isArray(state[collection]) || state[collection].length > MAX_COLLECTION_ITEMS) {
      fail("STORE_CORRUPT", `Store field ${collection} must be a bounded array.`);
    }
  }

  state.inbox.forEach(assertEnvelope);
  state.diagrams.forEach(assertDiagram);
  state.revisions.forEach(assertRevision);
  state.reviewMarks.forEach(assertReviewMark);
  return state;
}

function createEmptyState(timestamp) {
  return {
    schemaVersion: STORE_SCHEMA_VERSION,
    createdAt: timestamp,
    updatedAt: timestamp,
    inbox: [],
    diagrams: [],
    revisions: [],
    reviewMarks: [],
  };
}

export function defaultStorePath({
  env = process.env,
  platform = process.platform,
  homeDirectory = homedir(),
} = {}) {
  const override = env.REVIEW_CANVAS_DATA_DIR;
  if (override !== undefined) {
    if (typeof override !== "string" || !path.isAbsolute(override)) {
      fail("STORE_UNSAFE_PATH", "REVIEW_CANVAS_DATA_DIR must be an absolute path.");
    }
    return path.join(path.normalize(override), "store.json");
  }

  if (platform === "darwin") {
    return path.join(
      homeDirectory,
      "Library",
      "Application Support",
      "Review Canvas",
      "Inbox",
      "store.json",
    );
  }
  if (platform === "win32") {
    const base = env.LOCALAPPDATA || path.join(homeDirectory, "AppData", "Local");
    return path.join(base, "Review Canvas", "Inbox", "store.json");
  }
  const base = env.XDG_DATA_HOME || path.join(homeDirectory, ".local", "share");
  return path.join(base, "review-canvas", "Inbox", "store.json");
}

export class JsonStore {
  #tail = Promise.resolve();

  constructor(storePath, { now = () => new Date().toISOString() } = {}) {
    if (typeof storePath !== "string" || !path.isAbsolute(storePath)) {
      fail("STORE_UNSAFE_PATH", "Store path must be absolute.");
    }
    this.path = path.normalize(storePath);
    this.now = now;
  }

  async read() {
    let metadata;
    try {
      metadata = await lstat(this.path);
    } catch (error) {
      if (error?.code === "ENOENT") {
        return createEmptyState(this.now());
      }
      throw this.#storeIoError("read", error);
    }

    if (!metadata.isFile() || metadata.isSymbolicLink()) {
      fail("STORE_UNSAFE_PATH", "Store path must point to a regular file, not a symbolic link.");
    }
    if (metadata.size > MAX_STORE_BYTES) {
      fail("STORE_TOO_LARGE", `Store must be at most ${MAX_STORE_BYTES} bytes.`);
    }

    let contents;
    try {
      const handle = await open(this.path, fileConstants.O_RDONLY | fileConstants.O_NOFOLLOW);
      try {
        contents = await handle.readFile({ encoding: "utf8" });
      } finally {
        await handle.close();
      }
    } catch (error) {
      if (error?.code === "ELOOP") {
        fail("STORE_UNSAFE_PATH", "Store path must not be a symbolic link.");
      }
      throw this.#storeIoError("read", error);
    }

    let parsed;
    try {
      parsed = JSON.parse(contents);
    } catch (error) {
      fail("STORE_CORRUPT", "Store contains invalid JSON and was left unchanged.", undefined, {
        cause: error,
      });
    }
    return validateStoreState(parsed);
  }

  transaction(mutator) {
    if (typeof mutator !== "function") {
      return Promise.reject(new TypeError("mutator must be a function"));
    }

    return this.#runExclusive(async () => {
      const state = structuredClone(await this.read());
      const result = await mutator(state);
      state.updatedAt = this.now();
      validateStoreState(state);
      await this.#writeAtomic(state);
      return result;
    });
  }

  writeInboxEnvelope(envelope) {
    assertEnvelope(envelope, 0);
    return this.#runExclusive(async () => {
      const prepared = await this.#prepareInboxEnvelope(envelope);
      try {
        await this.#commitInboxEnvelope(prepared);
        return prepared.envelopePath;
      } catch (error) {
        await unlink(prepared.temporaryPath).catch(() => undefined);
        throw error;
      }
    });
  }

  queueInboxEnvelope(envelope, mutator) {
    assertEnvelope(envelope, 0);
    if (typeof mutator !== "function") {
      return Promise.reject(new TypeError("mutator must be a function"));
    }

    return this.#runExclusive(async () => {
      const previousState = structuredClone(await this.read());
      const nextState = structuredClone(previousState);
      const result = await mutator(nextState);
      nextState.updatedAt = this.now();
      validateStoreState(nextState);
      const prepared = await this.#prepareInboxEnvelope(envelope);

      try {
        await this.#writeAtomic(nextState);

        try {
          await this.#commitInboxEnvelope(prepared);
        } catch (commitError) {
          try {
            await this.#writeAtomic(previousState);
          } catch (rollbackError) {
            throw new ReviewCanvasError(
              "STORE_RECOVERY_REQUIRED",
              "Inbox envelope commit failed and store rollback was unsuccessful.",
              undefined,
              { cause: new AggregateError([commitError, rollbackError]) },
            );
          }
          throw commitError;
        }

        return result;
      } finally {
        await unlink(prepared.temporaryPath).catch(() => undefined);
      }
    });
  }

  recoverInterruptedQueues() {
    return this.#runExclusive(async () => {
      const directory = path.dirname(this.path);
      const entries = await readdir(directory, { withFileTypes: true }).catch((error) => {
        if (error?.code === "ENOENT") {
          return [];
        }
        throw this.#storeIoError("scan interrupted queues in", error);
      });
      const state = await this.read();
      let recovered = 0;
      let discarded = 0;
      const temporaryEnvelopePattern =
        /^\.diagram-([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.[0-9a-f-]{36}\.tmp$/iu;

      for (const entry of entries) {
        const match = temporaryEnvelopePattern.exec(entry.name);
        if (!match) {
          continue;
        }

        const temporaryPath = path.join(directory, entry.name);
        const envelope = state.inbox.find((candidate) => candidate.diagramId === match[1]);
        if (!entry.isFile() || !envelope) {
          await unlink(temporaryPath).catch(() => undefined);
          discarded += 1;
          continue;
        }

        const envelopePath = path.join(directory, `diagram-${envelope.diagramId}.json`);
        const finalExists = await lstat(envelopePath)
          .then(() => true)
          .catch((error) => {
            if (error?.code === "ENOENT") {
              return false;
            }
            throw this.#storeIoError("inspect an interrupted envelope in", error);
          });
        if (finalExists) {
          await unlink(temporaryPath).catch(() => undefined);
          discarded += 1;
          continue;
        }

        const replacement = await this.#prepareInboxEnvelope(envelope);
        await this.#commitInboxEnvelope(replacement);
        await unlink(temporaryPath).catch(() => undefined);
        recovered += 1;
      }

      return { recovered, discarded };
    });
  }

  async #prepareInboxEnvelope(envelope) {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
      envelope.diagramId,
    )) {
      fail("INVALID_ID", "Inbox envelope diagramId must be a UUID.");
    }

    const directory = path.dirname(this.path);
    const envelopePath = path.join(directory, `diagram-${envelope.diagramId}.json`);
    const temporaryPath = path.join(
      directory,
      `.diagram-${envelope.diagramId}.${randomUUID()}.tmp`,
    );
    let handle;

    try {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const existing = await lstat(envelopePath).catch((error) => {
        if (error?.code === "ENOENT") {
          return null;
        }
        throw error;
      });
      if (existing) {
        fail("INBOX_ENVELOPE_EXISTS", "Inbox envelope already exists.", {
          diagramId: envelope.diagramId,
        });
      }

      handle = await open(temporaryPath, "wx", 0o600);
      await handle.writeFile(`${JSON.stringify(envelope, null, 2)}\n`, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      return { temporaryPath, envelopePath };
    } catch (error) {
      if (handle) {
        await handle.close().catch(() => undefined);
      }
      await unlink(temporaryPath).catch(() => undefined);
      if (error instanceof ReviewCanvasError) {
        throw error;
      }
      throw this.#storeIoError("prepare the inbox envelope in", error);
    }
  }

  async #commitInboxEnvelope({ temporaryPath, envelopePath }) {
    const existing = await lstat(envelopePath).catch((error) => {
      if (error?.code === "ENOENT") {
        return null;
      }
      throw error;
    });
    if (existing) {
      fail("INBOX_ENVELOPE_EXISTS", "Inbox envelope already exists.");
    }
    try {
      await rename(temporaryPath, envelopePath);
    } catch (error) {
      if (error instanceof ReviewCanvasError) {
        throw error;
      }
      throw this.#storeIoError("commit the inbox envelope to", error);
    }
  }

  async #writeAtomic(state) {
    const directory = path.dirname(this.path);
    const temporaryPath = path.join(
      directory,
      `.${path.basename(this.path)}.${randomUUID()}.tmp`,
    );
    let handle;
    const serialized = `${JSON.stringify(state, null, 2)}\n`;
    if (Buffer.byteLength(serialized, "utf8") > MAX_STORE_BYTES) {
      fail("STORE_TOO_LARGE", `Store must be at most ${MAX_STORE_BYTES} bytes.`);
    }

    try {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const existing = await lstat(this.path).catch((error) => {
        if (error?.code === "ENOENT") {
          return null;
        }
        throw error;
      });
      if (existing?.isSymbolicLink() || (existing && !existing.isFile())) {
        fail("STORE_UNSAFE_PATH", "Store path must point to a regular file.");
      }

      handle = await open(temporaryPath, "wx", 0o600);
      await handle.writeFile(serialized, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(temporaryPath, this.path);
    } catch (error) {
      if (handle) {
        await handle.close().catch(() => undefined);
      }
      await unlink(temporaryPath).catch(() => undefined);
      if (error instanceof ReviewCanvasError) {
        throw error;
      }
      throw this.#storeIoError("write", error);
    }
  }

  #storeIoError(operation, cause) {
    return new ReviewCanvasError(
      "STORE_IO_ERROR",
      `Could not ${operation} the Review Canvas store.`,
      undefined,
      { cause },
    );
  }

  #runExclusive(operation) {
    const pending = this.#tail.then(() => this.#withFileLock(operation));
    this.#tail = pending.catch(() => undefined);
    return pending;
  }

  async #withFileLock(operation) {
    const release = await this.#acquireFileLock();
    try {
      return await operation();
    } finally {
      await release();
    }
  }

  async #acquireFileLock() {
    const directory = path.dirname(this.path);
    const lockPath = `${this.path}.lock`;
    const token = randomUUID();
    const deadline = Date.now() + LOCK_ACQUIRE_TIMEOUT_MS;
    await mkdir(directory, { recursive: true, mode: 0o700 });

    while (true) {
      let handle;
      let created = false;
      try {
        handle = await open(lockPath, "wx", 0o600);
        created = true;
        await handle.writeFile(
          JSON.stringify({ token, pid: process.pid, createdAt: new Date().toISOString() }),
          "utf8",
        );
        await handle.sync();
        await handle.close();

        return async () => {
          try {
            const lock = JSON.parse(await readFile(lockPath, "utf8"));
            if (lock.token === token) {
              await unlink(lockPath);
            }
          } catch (error) {
            if (error?.code !== "ENOENT") {
              throw this.#storeIoError("release the lock for", error);
            }
          }
        };
      } catch (error) {
        if (handle) {
          await handle.close().catch(() => undefined);
        }
        if (created) {
          await unlink(lockPath).catch(() => undefined);
        }
        if (error?.code !== "EEXIST") {
          throw this.#storeIoError("lock", error);
        }

        const metadata = await lstat(lockPath).catch((statError) => {
          if (statError?.code === "ENOENT") {
            return null;
          }
          throw statError;
        });
        if (!metadata) {
          continue;
        }
        if (!metadata.isFile() || metadata.isSymbolicLink()) {
          fail("STORE_UNSAFE_PATH", "Store lock must be a regular file.");
        }
        const lockOwner = await readFile(lockPath, "utf8")
          .then((contents) => JSON.parse(contents))
          .catch(() => null);
        if (lockOwner && isProcessAlive(lockOwner.pid) === false) {
          await unlink(lockPath).catch(() => undefined);
          continue;
        }
        if (Date.now() - metadata.mtimeMs > LOCK_STALE_AFTER_MS) {
          await unlink(lockPath).catch(() => undefined);
          continue;
        }
        if (Date.now() >= deadline) {
          fail("STORE_BUSY", "Review Canvas store is busy; retry the request.");
        }
        await delay(20);
      }
    }
  }
}
