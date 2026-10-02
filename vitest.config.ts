import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The domain engines are pure (SDD §17.2) — no DOM, no environment setup,
    // no clock: `today` is injected, so the fixture tables are deterministic.
    //
    // The UI primitives are server components, so their tests render to static
    // markup with react-dom/server and need no DOM either.
    environment: "node",
    include: ["lib/**/*.test.ts", "components/**/*.test.{ts,tsx}"],
  },
});
