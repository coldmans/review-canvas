import { setTimeout as delay } from "node:timers/promises";

import { JsonStore } from "../src/store.js";

const storePath = process.argv[2];
if (!storePath) {
  throw new Error("store path argument is required");
}

const store = new JsonStore(storePath);
await store.transaction(async (state) => {
  const current = state.processTransactionCount ?? 0;
  await delay(75);
  state.processTransactionCount = current + 1;
});
