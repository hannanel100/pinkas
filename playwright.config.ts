import { defineConfig, devices } from "@playwright/test";

/**
 * SDD §17.3 — smoke tests over the four screens in RTL at 375px, plus an
 * automated axe pass for §18.2.
 *
 * 375px is not a breakpoint chosen for coverage; CLAUDE.md says design for it
 * first, literally. Testing at a desktop width would test a layout the product
 * does not target.
 */
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",

  use: {
    baseURL: "http://127.0.0.1:3000",
    trace: "on-first-retry",
    locale: "he-IL",
    timezoneId: "Asia/Jerusalem",
  },

  projects: [
    {
      name: "mobile-rtl",
      use: { ...devices["iPhone SE"] },
    },
  ],

  webServer: {
    command: "pnpm run build && pnpm run start",
    url: "http://127.0.0.1:3000/today",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
