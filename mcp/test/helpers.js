import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

export async function withTemporaryDirectory(run) {
  const directory = await mkdtemp(path.join(tmpdir(), "review-canvas-mcp-"));

  try {
    return await run(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export function sequenceIdGenerator(ids) {
  const remaining = [...ids];

  return () => {
    const id = remaining.shift();
    if (!id) {
      throw new Error("Test ID sequence exhausted");
    }
    return id;
  };
}

export const DIAGRAM_ID = "00000000-0000-4000-8000-000000000001";
export const INITIAL_REVISION_ID = "00000000-0000-4000-8000-000000000002";
export const NEXT_REVISION_ID = "00000000-0000-4000-8000-000000000003";
export const MARK_ID = "00000000-0000-4000-8000-000000000004";
