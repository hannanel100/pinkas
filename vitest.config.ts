import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The domain engines are pure (SDD §17.2) — no DOM, no environment setup,
    // no clock: `today` is injected, so the fixture tables are deterministic.
    environment: "node",
    include: ["lib/**/*.test.ts"],
  },
});
