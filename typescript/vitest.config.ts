import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    include: ["tests/**/*.test.ts"],
    // Every suite in here talks to a real socket or a fake one on real timers,
    // and a hung await should be reported rather than waited out.
    testTimeout: 20_000,
  },
});
