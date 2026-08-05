export const STORE_SCHEMA_VERSION = 1;
export const MAX_MERMAID_BYTES = 1024 * 1024;
export const MAX_STORE_BYTES = 64 * 1024 * 1024;
export const MAX_COLLECTION_ITEMS = 10_000;
export const MAX_REVIEW_MARK_BODY_LENGTH = 16_000;
export const MAX_REVIEW_MARK_SYMBOL_LENGTH = 16;
export const MAX_REVIEW_MARK_ANCHOR_BYTES = 4_096;
export const MAX_TITLE_LENGTH = 200;
export const MAX_SUMMARY_LENGTH = 2_000;

export const TARGET_DEVICES = Object.freeze(["any", "mac", "ipad"]);
export const REVIEW_MARK_STATUSES = Object.freeze([
  "open",
  "inProgress",
  "resolved",
  "dismissed",
]);
export const REVIEW_MARK_TYPES = Object.freeze(["explain", "change", "verify"]);
export const REVISION_STATUSES = Object.freeze([
  "current",
  "proposed",
  "rejected",
  "superseded",
]);

export const SUPPORTED_DIAGRAM_KEYWORDS = Object.freeze([
  "architecture-beta",
  "block-beta",
  "classDiagram",
  "erDiagram",
  "flowchart",
  "gantt",
  "gitGraph",
  "graph",
  "journey",
  "kanban",
  "mindmap",
  "packet-beta",
  "pie",
  "quadrantChart",
  "radar-beta",
  "requirementDiagram",
  "sankey-beta",
  "sequenceDiagram",
  "stateDiagram",
  "stateDiagram-v2",
  "timeline",
  "treemap-beta",
  "xychart-beta",
  "zenuml",
]);
