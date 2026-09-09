import { defineConfig } from "vitest/config";

// vitest only owns host/client unit tests (*.test.js). Playwright owns the
// browser specs under test/e2e/*.spec.js — keep the two runners disjoint.
export default defineConfig({
  test: {
    include: ["test/**/*.test.js"],
    exclude: ["test/e2e/**", "node_modules/**"],
  },
});
