import { expect, test } from "@playwright/test";

/**
 * Scaffold-level checks only: that the RTL document shell and the route-group
 * split are real. The four screen smoke tests of SDD §17.3 and the axe pass of
 * §18.2 are ticketed to `qa` and land with the screens themselves.
 */

test("instructor shell is RTL Hebrew", async ({ page }) => {
  await page.goto("/today");
  const html = page.locator("html");
  await expect(html).toHaveAttribute("dir", "rtl");
  await expect(html).toHaveAttribute("lang", "he");
});

test("the root path leads to Today", async ({ page }) => {
  // PRD §8 — Today is the product; there is no separate home.
  await page.goto("/");
  await expect(page).toHaveURL(/\/today$/);
});

test("portal routes are not indexable and leak no referrer", async ({
  page,
}) => {
  // SDD §6.2/§6.3 — the URL is the credential.
  const response = await page.goto("/p/scaffold-placeholder-token");
  expect(response?.headers()["x-robots-tag"]).toContain("noindex");
  expect(response?.headers()["referrer-policy"]).toBe("no-referrer");
});

test("the portal shell shares no navigation with the instructor app", async ({
  page,
}) => {
  await page.goto("/p/scaffold-placeholder-token");
  // Note d1: no navigation, no menu, no logo.
  await expect(page.locator("nav")).toHaveCount(0);
});
