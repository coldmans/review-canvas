import { randomUUID } from "node:crypto";

import { fail } from "./errors.js";
import {
  validateId,
  validateInputObject,
  validateMermaid,
  validateReviewStatus,
  validateReviewType,
  validateSummary,
  validateTargetDevice,
  validateTitle,
} from "./validation.js";

export class ReviewCanvasService {
  constructor({
    store,
    now = () => new Date().toISOString(),
    idGenerator = randomUUID,
  }) {
    if (!store) {
      throw new TypeError("store is required");
    }
    this.store = store;
    this.now = now;
    this.idGenerator = idGenerator;
  }

  async sendDiagram(input) {
    const args = validateInputObject(input);
    const title = validateTitle(args.title);
    const source = await validateMermaid(args.mermaid);
    const targetDevice = validateTargetDevice(args.targetDevice);
    const diagramId = this.idGenerator();
    const revisionId = this.idGenerator();
    validateId(diagramId, "diagramId");
    validateId(revisionId, "revisionId");
    const timestamp = this.now();
    const envelope = {
      schemaVersion: 1,
      diagramId,
      title,
      targetDevice,
      createdAt: timestamp,
      revision: {
        id: revisionId,
        parentRevisionId: null,
        sequence: 1,
        status: "current",
        source,
      },
    };

    await this.store.queueInboxEnvelope(envelope, (state) => {
      if (state.diagrams.some((diagram) => diagram.id === diagramId)) {
        fail("ID_CONFLICT", "Generated diagram ID already exists.");
      }
      if (state.revisions.some((revision) => revision.id === revisionId)) {
        fail("ID_CONFLICT", "Generated revision ID already exists.");
      }

      state.inbox.push(envelope);
      state.diagrams.push({
        id: diagramId,
        title,
        targetDevice,
        status: "queued",
        currentRevisionId: revisionId,
        headRevisionId: revisionId,
        createdAt: timestamp,
        updatedAt: timestamp,
      });
      state.revisions.push({
        id: revisionId,
        diagramId,
        parentRevisionId: null,
        sequence: 1,
        source,
        summary: null,
        status: "current",
        createdAt: timestamp,
      });
    });
    return { diagramId, revisionId, status: "queued" };
  }

  async listReviewMarks(input = {}) {
    await this.store.ingestReviewOutbox?.();
    const args = validateInputObject(input);
    const diagramId =
      args.diagramId === undefined ? undefined : validateId(args.diagramId, "diagramId");
    const status = validateReviewStatus(args.status, { optional: true });
    const type = validateReviewType(args.type, { optional: true });
    const state = await this.store.read();

    const marks = state.reviewMarks
      .filter(
        (mark) =>
          (diagramId === undefined || mark.diagramId === diagramId) &&
          (status === undefined || mark.status === status) &&
          (type === undefined || mark.type === type),
      )
      .map((mark) => ({
        id: mark.id,
        diagramId: mark.diagramId,
        revisionId: mark.revisionId,
        type: mark.type,
        symbol: mark.symbol,
        body: mark.body,
        status: mark.status,
        ...(mark.anchor === undefined ? {} : { anchor: mark.anchor }),
        createdAt: mark.createdAt,
        updatedAt: mark.updatedAt,
        resolvedAt: mark.resolvedAt,
      }));

    return { count: marks.length, marks };
  }

  async proposeRevision(input) {
    await this.store.ingestReviewOutbox?.();
    const args = validateInputObject(input);
    const diagramId = validateId(args.diagramId, "diagramId");
    const expectedRevisionId = validateId(args.expectedRevisionId, "expectedRevisionId");
    const source = await validateMermaid(args.mermaid);
    const summary = validateSummary(args.summary);
    let revisionId;
    let parentRevisionId;

    await this.store.transaction((state) => {
      const diagram = state.diagrams.find((candidate) => candidate.id === diagramId);
      if (!diagram) {
        fail("DIAGRAM_NOT_FOUND", "Diagram was not found.", { diagramId });
      }
      if (diagram.headRevisionId !== expectedRevisionId) {
        fail("REVISION_CONFLICT", "The diagram has changed since the expected revision.", {
          expectedRevisionId,
          actualRevisionId: diagram.headRevisionId,
        });
      }
      const parent = state.revisions.find(
        (candidate) => candidate.id === expectedRevisionId && candidate.diagramId === diagramId,
      );
      if (!parent) {
        fail("REVISION_NOT_FOUND", "Expected revision was not found.", {
          diagramId,
          expectedRevisionId,
        });
      }
      revisionId = this.idGenerator();
      validateId(revisionId, "revisionId");
      if (state.revisions.some((candidate) => candidate.id === revisionId)) {
        fail("ID_CONFLICT", "Generated revision ID already exists.");
      }

      const timestamp = this.now();
      parentRevisionId = parent.id;
      state.revisions.push({
        id: revisionId,
        diagramId,
        parentRevisionId,
        sequence: parent.sequence + 1,
        source,
        summary,
        status: "proposed",
        createdAt: timestamp,
      });
      diagram.headRevisionId = revisionId;
      diagram.updatedAt = timestamp;
    });

    return {
      diagramId,
      revisionId,
      parentRevisionId,
      status: "proposed",
    };
  }

  async resolveReviewMark(input) {
    await this.store.ingestReviewOutbox?.();
    const args = validateInputObject(input);
    const diagramId = validateId(args.diagramId, "diagramId");
    const markId = validateId(args.markId, "markId");
    const expectedStatus = validateReviewStatus(args.expectedStatus, { optional: true });
    const timestamp = this.now();

    await this.store.transaction((state) => {
      const mark = state.reviewMarks.find((candidate) => candidate.id === markId);
      if (!mark) {
        fail("MARK_NOT_FOUND", "Review mark was not found.", { markId });
      }
      if (mark.diagramId !== diagramId) {
        fail("MARK_DIAGRAM_MISMATCH", "Review mark does not belong to the diagram.", {
          diagramId,
          markId,
        });
      }
      if (expectedStatus !== undefined && mark.status !== expectedStatus) {
        fail("MARK_STATUS_CONFLICT", "Review mark status has changed.", {
          expectedStatus,
          actualStatus: mark.status,
        });
      }
      if (mark.status !== "resolved") {
        mark.status = "resolved";
        mark.updatedAt = timestamp;
        mark.resolvedAt = timestamp;
      }
    });

    return { diagramId, markId, status: "resolved" };
  }
}
