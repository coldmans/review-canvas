import { Buffer } from "node:buffer";

import mermaid from "mermaid";

import {
  MAX_MERMAID_BYTES,
  MAX_SUMMARY_LENGTH,
  MAX_TITLE_LENGTH,
  REVIEW_MARK_STATUSES,
  REVIEW_MARK_TYPES,
  SUPPORTED_DIAGRAM_KEYWORDS,
  TARGET_DEVICES,
} from "./constants.js";
import { fail } from "./errors.js";

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

mermaid.initialize({ startOnLoad: false, securityLevel: "strict" });

export function validateInputObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("INVALID_ARGUMENT", "Tool arguments must be a JSON object.");
  }
  return value;
}
export function validateId(value, fieldName) {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    fail("INVALID_ID", `${fieldName} must be a UUID.`, { field: fieldName });
  }
  return value;
}

export function validateTitle(value) {
  if (typeof value !== "string") {
    fail("INVALID_ARGUMENT", "title must be a string.", { field: "title" });
  }

  const title = value.trim();
  if (title.length === 0 || title.length > MAX_TITLE_LENGTH || title.includes("\0")) {
    fail(
      "INVALID_ARGUMENT",
      `title must contain 1-${MAX_TITLE_LENGTH} characters.`,
      { field: "title" },
    );
  }
  return title;
}

export function validateTargetDevice(value) {
  const targetDevice = value ?? "any";
  if (!TARGET_DEVICES.includes(targetDevice)) {
    fail("INVALID_ARGUMENT", `targetDevice must be one of: ${TARGET_DEVICES.join(", ")}.`, {
      field: "targetDevice",
      allowed: TARGET_DEVICES,
    });
  }
  return targetDevice;
}

export function validateSummary(value) {
  if (value === undefined) {
    return null;
  }
  if (typeof value !== "string" || value.length > MAX_SUMMARY_LENGTH || value.includes("\0")) {
    fail(
      "INVALID_ARGUMENT",
      `summary must be a string of at most ${MAX_SUMMARY_LENGTH} characters.`,
      { field: "summary" },
    );
  }
  return value.trim() || null;
}

export function validateReviewStatus(value, { optional = false } = {}) {
  if (optional && value === undefined) {
    return undefined;
  }
  if (!REVIEW_MARK_STATUSES.includes(value)) {
    fail("INVALID_STATUS", `status must be one of: ${REVIEW_MARK_STATUSES.join(", ")}.`, {
      field: "status",
      allowed: REVIEW_MARK_STATUSES,
    });
  }
  return value;
}

export function validateReviewType(value, { optional = false } = {}) {
  if (optional && value === undefined) {
    return undefined;
  }
  if (!REVIEW_MARK_TYPES.includes(value)) {
    fail("INVALID_TYPE", `type must be one of: ${REVIEW_MARK_TYPES.join(", ")}.`, {
      field: "type",
      allowed: REVIEW_MARK_TYPES,
    });
  }
  return value;
}

export async function validateMermaid(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    fail("INVALID_MERMAID", "mermaid must contain a diagram.", { field: "mermaid" });
  }

  const byteLength = Buffer.byteLength(value, "utf8");
  if (byteLength > MAX_MERMAID_BYTES) {
    fail("DIAGRAM_TOO_LARGE", `Mermaid source must be at most ${MAX_MERMAID_BYTES} bytes.`, {
      field: "mermaid",
      byteLength,
      maximumBytes: MAX_MERMAID_BYTES,
    });
  }

  const firstDiagramLine = value
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .find((line) => line.length > 0 && !line.startsWith("%%"));
  const keyword = firstDiagramLine?.split(/[\s{]/u, 1)[0];

  if (!keyword || !SUPPORTED_DIAGRAM_KEYWORDS.includes(keyword)) {
    fail("INVALID_MERMAID", "Mermaid source must begin with a supported diagram keyword.", {
      field: "mermaid",
      keyword: keyword ?? null,
    });
  }

  try {
    const parsed = await mermaid.parse(value, { suppressErrors: true });
    if (!parsed) {
      fail("INVALID_MERMAID", "Mermaid source could not be parsed.", { field: "mermaid" });
    }
  } catch (error) {
    if (error?.code === "INVALID_MERMAID") {
      throw error;
    }
    fail("INVALID_MERMAID", "Mermaid source could not be parsed.", { field: "mermaid" }, {
      cause: error,
    });
  }

  return value;
}
