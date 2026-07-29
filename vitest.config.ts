import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The domain engines are pure (SDD §17.2) — no DOM, no environment setup,
    // no clock: `today` is injected, so the fixture tables are deterministic.
    environment: "node",
    include: ["lib/**/*.test.ts"],

    // lib/ is empty in the scaffold; the engines and their fixture tables are
    // ticketed to `domain`. Remove this line once the first test lands, so an
    // empty suite goes back to being a failure.
    passWithNoTests: true,
  },
});
