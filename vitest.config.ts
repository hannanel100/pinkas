import { fileURLToPath } from "node:url";

import { defineConfig } from "vitest/config";

export default defineConfig({
  // Mirrors tsconfig's `@/*` path, so tests import the way the app does.
  resolve: {
    alias: {
      "@": fileURLToPath(new URL(".", import.meta.url)),
      // `server-only` throws unless resolved under the react-server condition,
      // which Next applies to server code and Vitest does not. Tests run on the
      // server by definition, so they get the package's own empty module.
      // The marker still does its job in `next build`.
      "server-only": fileURLToPath(
        new URL("./node_modules/server-only/empty.js", import.meta.url),
      ),
    },
  },
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
