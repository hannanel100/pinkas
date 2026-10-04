import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

/**
 * CLAUDE.md: "Each one is enforced by a test or a lint rule, not by review
 * discipline — so breaking one should show up as a failure. Do not work around
 * the failure; the constraint is the point."
 *
 * This file is that enforcement. Each rule names the invariant it implements.
 * If one fires, the fix is almost never an eslint-disable.
 *
 * ── A structural warning, because it has already bitten once ──────────────
 *
 * ESLint flat config *replaces* a rule when a later block redefines it; the
 * entries are not merged. Two blocks that both match `components/**` and both
 * set `no-restricted-syntax` means the second silently wins and the first
 * stops enforcing anything.
 *
 * So the rules are composed from the shared arrays below and each scope
 * defines each rule exactly once. Before adding a block, check that no other
 * block matching the same files sets the same rule — and verify by writing a
 * violation and watching it fail. A rule that passes on clean code proves
 * nothing.
 *
 * These are lexical checks, not type-aware ones, and deliberately blunt: a rule
 * that occasionally needs a justified disable is worth more than one nobody can
 * read. typescript-eslint's type-aware rules are unavailable while the
 * toolchain runs TypeScript 7 (see README); none of the boundaries below need
 * them.
 */

/* ── Shared matchers ─────────────────────────────────────────────────────── */

const HEX_COLOUR = /#[0-9a-fA-F]{3}/;

// Tailwind physical-direction utilities. RTL is the only direction Phase 1
// ships, so these are always a bug — a logical equivalent exists for each.
const PHYSICAL_UTILITY =
  /(?:^|[\s"'`])(?:-?m[lr]|-?p[lr]|left|right|text-left|text-right|border-[lr]|rounded-[lr]|float-left|float-right|inset-[lr])-/;

const PHYSICAL_PROPERTY =
  /^(?:marginLeft|marginRight|paddingLeft|paddingRight|left|right|borderLeft|borderRight|borderLeftWidth|borderRightWidth|borderLeftColor|borderRightColor)$/;

const RISK_TOKEN = /(?:^|[\s"'`-])risk-[123]\b/;

// Any Hebrew letter. Product copy is Hebrew, and it lives in lib/i18n/.
const HEBREW = /[\u0590-\u05FF]/;

/* ── no-restricted-syntax fragments ──────────────────────────────────────── */

/** Invariant 8 — RTL is the only direction. SDD §10.3, §11. */
const rtlSyntax = [
  {
    selector: `Literal[value=${PHYSICAL_UTILITY.toString()}]`,
    message:
      "Physical direction utility. RTL is the only direction (invariant 8, SDD §11) — use the logical equivalent: ms-/me-, ps-/pe-, start-/end-, text-start/text-end, border-s/border-e.",
  },
  {
    selector: `TemplateElement[value.raw=${PHYSICAL_UTILITY.toString()}]`,
    message:
      "Physical direction utility. RTL is the only direction (invariant 8, SDD §11).",
  },
  {
    selector: `Property[key.name=${PHYSICAL_PROPERTY.toString()}]`,
    message:
      "Physical CSS property. Use the logical property — marginInlineStart, paddingInlineEnd, insetInlineStart. Invariant 8, SDD §11.",
  },
];

/** Invariant 7 — colour carries exactly one meaning: risk. SDD §10.2. */
const colourSyntax = [
  {
    selector: `Literal[value=${HEX_COLOUR.toString()}]`,
    message:
      "Raw hex colour. The token set is closed (invariant 7, SDD §10.2) — app/globals.css is the only place colour is defined.",
  },
  {
    selector: `TemplateElement[value.raw=${HEX_COLOUR.toString()}]`,
    message: "Raw hex colour. The token set is closed (invariant 7, SDD §10.2).",
  },
  {
    selector: "CallExpression[callee.name=/^(?:rgb|rgba|hsl|hsla|oklch)$/]",
    message:
      "Computed colour. The token set is closed (invariant 7), and only components/risk/ emits colour at all.",
  },
];

/**
 * Invariant 8 — strings live in a translation layer (SDD §11). Copy in a
 * component cannot be composed from a reason code (§8.3), so a Hebrew literal
 * under app/ or components/ is always a string that belongs in lib/i18n/he.ts.
 */
const copySyntax = [
  {
    selector: `Literal[value=${HEBREW.toString()}]`,
    message:
      "Hebrew string literal in a component. Copy lives in the translation layer (invariant 8, SDD §11) — add it to lib/i18n/he.ts and read it through `t`.",
  },
  {
    selector: `TemplateElement[value.raw=${HEBREW.toString()}]`,
    message:
      "Hebrew string literal in a component. Copy lives in lib/i18n/he.ts (invariant 8, SDD §11).",
  },
  {
    selector: `JSXText[value=${HEBREW.toString()}]`,
    message:
      "Hebrew copy in JSX. Copy lives in lib/i18n/he.ts (invariant 8, SDD §11).",
  },
];

/** The other half of invariant 7: only components/risk/ names the risk tokens. */
const riskTokenSyntax = [
  {
    selector: `Literal[value=${RISK_TOKEN.toString()}]`,
    message:
      "risk-* tokens may only be referenced inside components/risk/ (invariant 7, SDD §10.2). Render risk through a component from there.",
  },
  {
    selector: `TemplateElement[value.raw=${RISK_TOKEN.toString()}]`,
    message:
      "risk-* tokens may only be referenced inside components/risk/ (invariant 7, SDD §10.2).",
  },
];

/**
 * Invariant 5 — SUPABASE_SERVICE_ROLE_KEY is in no deployed environment
 * (ADR-0010 §3), so nothing under app/, lib/ or components/ may name it: as
 * an identifier (`process.env.SUPABASE_SERVICE_ROLE_KEY`), a string
 * (`process.env["…"]`) or inside a template. scripts/ is exempt — the staging
 * harness lives there.
 *
 * This is a TRIPWIRE, not the control. It is lexical: string concatenation
 * (`"SUPABASE_SERVICE" + "_ROLE_KEY"`) or iterating `process.env` walks past it.
 * The control is ADR-0010 §3 — the key is in no deployed environment, so code
 * that found a way to name it would still read `undefined`. The lint exists to
 * make the honest mistake loud, not to stop a determined one.
 */
const SERVICE_KEY = /SUPABASE_SERVICE_ROLE_KEY/;
const SERVICE_KEY_MESSAGE =
  "SUPABASE_SERVICE_ROLE_KEY is in no deployed environment and may not be named under app/, lib/ or components/ (invariant 5, ADR-0010). The portal's credential is PORTAL_DATABASE_URL, read in lib/data/portal.ts only.";
const serviceKeySyntax = [
  { selector: `Identifier[name=${SERVICE_KEY.toString()}]`, message: SERVICE_KEY_MESSAGE },
  { selector: `Literal[value=${SERVICE_KEY.toString()}]`, message: SERVICE_KEY_MESSAGE },
  { selector: `TemplateElement[value.raw=${SERVICE_KEY.toString()}]`, message: SERVICE_KEY_MESSAGE },
];

/**
 * Invariant 5 — PORTAL_DATABASE_URL is read in lib/data/portal.ts and nowhere
 * else (ADR-0010 §1). Same three forms as the service-key ban above, applied
 * to app/, lib/ and components/ with portal.ts the one exemption.
 *
 * Also a TRIPWIRE, not the control: concatenation or iterating `process.env`
 * walks past a lexical rule. The control is ADR-0010 — the credential is a
 * `portal_reader` login holding EXECUTE on the portal_* functions and nothing
 * else, so code that reached it from elsewhere could still only call those
 * functions, each of which looks up by token hash and logs its own read.
 */
const PORTAL_URL = /PORTAL_DATABASE_URL/;
const PORTAL_URL_MESSAGE =
  "PORTAL_DATABASE_URL is read in lib/data/portal.ts only (invariant 5, ADR-0010). Reach the portal through that module's functions.";
const portalUrlSyntax = [
  { selector: `Identifier[name=${PORTAL_URL.toString()}]`, message: PORTAL_URL_MESSAGE },
  { selector: `Literal[value=${PORTAL_URL.toString()}]`, message: PORTAL_URL_MESSAGE },
  { selector: `TemplateElement[value.raw=${PORTAL_URL.toString()}]`, message: PORTAL_URL_MESSAGE },
];

/** Invariant 4 — `today` is injected, never read from the clock. SDD §2.4. */
const noClockSyntax = [
  {
    selector: "NewExpression[callee.name='Date'][arguments.length=0]",
    message:
      "The engines never read the clock — `today` is injected (invariant 4, SDD §2.4). An engine that reads the clock cannot be tested against a fixture table.",
  },
  {
    selector:
      "CallExpression[callee.object.name='Date'][callee.property.name='now']",
    message:
      "The engines never read the clock — `today` is injected (invariant 4, SDD §2.4).",
  },
];

/* ── no-restricted-imports fragments ─────────────────────────────────────── */

/** Invariant 3 — lib/data/ is the only door to the database. SDD §13. */
const supabaseClientPaths = [
  {
    name: "@supabase/supabase-js",
    message:
      "Construct clients only in lib/supabase/ (invariant 3, SDD §13). Postgres has no AFTER SELECT, so the access log PRD §10.1 requires is complete only if reads happen in one place.",
  },
  {
    name: "@supabase/ssr",
    message: "Construct clients only in lib/supabase/ (invariant 3, SDD §13).",
  },
];

/**
 * Invariant 5 — there is no service-role client (ADR-0010). The portal has its
 * own database credential, PORTAL_DATABASE_URL, read in lib/data/portal.ts
 * only, which calls only the portal_* functions. A lib/supabase/service module
 * would be the old design returning; importing one is an error everywhere.
 */
const serviceRolePattern = {
  group: ["@/lib/supabase/service", "**/supabase/service", "./service", "../supabase/service"],
  message:
    "There is no service-role client (invariant 5, ADR-0010). The portal reads through PORTAL_DATABASE_URL in lib/data/portal.ts only, which calls only the portal_* functions.",
};

/**
 * Invariant 3, one step in — the user-JWT client is imported by
 * lib/data/context.ts and nothing else. context.ts hands a client only to the
 * body of defineRead / defineMutation, whose wrappers write the access log, so
 * a function that does not log cannot obtain a client (#7 design challenge).
 */
const userClientPattern = {
  group: ["@/lib/supabase/user", "**/supabase/user", "../supabase/user", "../../supabase/user"],
  message:
    "Only lib/data/context.ts may import the user-JWT client (invariant 3, SDD §13). Define the access as a defineRead/defineMutation in lib/data/ — that is what writes the access log.",
};

/**
 * Data functions are defined inside lib/data/ only. A defineRead in a page
 * would still log, but it would be a second door — the review surface for
 * bride-data access is lib/data/, and that is only true if it is the only
 * place access can be defined.
 */
const defineOutsidePattern = {
  // A `patterns` entry, not `paths`: `paths` matches the literal specifier
  // only, so `../../../lib/data/context` walked straight past it (#60 review).
  group: ["@/lib/data/context", "**/data/context"],
  importNames: ["defineRead", "defineMutation"],
  message:
    "Data functions are defined in lib/data/ only (invariant 3, SDD §13). Import the function you need from its lib/data/ module.",
};

/** Invariant 4 — lib/domain/ imports nothing that does I/O. SDD §2.4. */
const domainPurityPattern = {
  group: [
    "@/lib/data",
    "@/lib/data/**",
    "@/lib/supabase",
    "@/lib/supabase/**",
    "**/lib/data/**",
    "**/lib/supabase/**",
    "@supabase/**",
    "server-only",
    "next",
    "next/**",
    "react",
    "react-dom",
    "node:*",
  ],
  message:
    "lib/domain/ does no I/O and imports nothing from the data or framework layers (invariant 4, SDD §2.4). This is what makes the fixture tests in §17.2 possible.",
};

/**
 * Each instructor module in all three forms an import can take: the alias,
 * a relative path through `data/` (from app/(portal)/), and a sibling path
 * (from lib/data/portal.ts). Gitignore-style groups match the specifier text,
 * not the resolved file, so every form has to be named (#60 review).
 */
const INSTRUCTOR_DATA_MODULES = [
  "brides",
  "courses",
  "sessions",
  "records",
  "today",
  "instructor",
  "context",
  "audit",
  "internal/records",
];
const portalCannotReachInstructorData = {
  group: INSTRUCTOR_DATA_MODULES.flatMap((m) => [
    `@/lib/data/${m}`,
    `**/data/${m}`,
    `./${m}`,
  ]),
  message:
    "The bride portal is Path 2 (untrusted). It reaches the database through lib/data/portal.ts and nothing else — PORTAL_DATABASE_URL, the portal_* functions only (invariant 5, ADR-0010, SDD §2.3).",
};

const instructorCannotReachPortalData = {
  group: ["@/lib/data/portal", "**/data/portal", "./portal", "../portal"],
  message:
    "Instructor code must not import lib/data/portal.ts — it holds PORTAL_DATABASE_URL and calls only the portal_* functions (invariant 5, ADR-0010, SDD §13).",
};

/* ── Config ──────────────────────────────────────────────────────────────── */

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,

  globalIgnores([
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "supabase/migrations/**",
  ]),

  {
    // Baseline for every file. More specific scopes below REDEFINE
    // no-restricted-imports and must therefore repeat these fragments.
    name: "pinkas/baseline-imports",
    files: ["**/*.{ts,tsx,mts}"],
    ignores: ["lib/supabase/**", "lib/data/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [serviceRolePattern, userClientPattern, defineOutsidePattern],
        },
      ],
    },
  },

  {
    // The instructor data layer. Instructor modules cannot reach the portal
    // module (invariant 5), and only context.ts holds the user client.
    name: "pinkas/data-layer",
    files: ["lib/data/**/*.ts"],
    ignores: ["lib/data/portal.ts", "lib/data/context.ts"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [
            serviceRolePattern,
            userClientPattern,
            instructorCannotReachPortalData,
          ],
        },
      ],
    },
  },
  {
    name: "pinkas/data-context",
    files: ["lib/data/context.ts"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [serviceRolePattern, instructorCannotReachPortalData],
        },
      ],
    },
  },
  {
    // lib/data/portal.ts (#53/#54) — Path 2. No Supabase client of any kind
    // and no instructor data module: its only database edge is
    // PORTAL_DATABASE_URL and the portal_* functions (ADR-0010).
    name: "pinkas/portal-module",
    files: ["lib/data/portal.ts"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [
            serviceRolePattern,
            userClientPattern,
            portalCannotReachInstructorData,
          ],
        },
      ],
    },
  },

  {
    // Test doubles and the test-only PostgREST client factory (which builds a
    // client on any JWT it is handed) are reachable from tests only (#60
    // review). A different rule from no-restricted-imports, and resolved-path
    // based, so it neither collides with the blocks above nor misses a
    // relative specifier.
    name: "pinkas/test-support-is-test-only",
    files: ["**/*.{ts,tsx,mts}"],
    ignores: ["**/*.test.{ts,tsx}", "lib/data/testing/**", "lib/supabase/testing/**"],
    rules: {
      "import/no-restricted-paths": [
        "error",
        {
          zones: [
            {
              target: "./",
              from: ["./lib/data/testing", "./lib/supabase/testing"],
              message:
                "Test support is importable from *.test.ts only — it fakes or bypasses the access log (#60 review).",
            },
          ],
        },
      ],
    },
  },

  {
    name: "pinkas/ui-surfaces",
    files: ["app/**/*.{ts,tsx}", "components/**/*.{ts,tsx}"],
    ignores: ["components/risk/**"],
    rules: {
      "no-restricted-syntax": [
        "error",
        ...rtlSyntax,
        ...copySyntax,
        ...colourSyntax,
        ...riskTokenSyntax,
        ...serviceKeySyntax,
        ...portalUrlSyntax,
      ],
    },
  },
  {
    // components/risk/ is the one place the risk tokens are legal. Everything
    // else about it — RTL, no raw hex — still applies.
    name: "pinkas/risk-components",
    files: ["components/risk/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-syntax": [
        "error",
        ...rtlSyntax,
        ...copySyntax,
        ...colourSyntax,
        ...serviceKeySyntax,
        ...portalUrlSyntax,
      ],
    },
  },

  {
    // The rest of lib/ has no other no-restricted-syntax rule; lib/domain/
    // composes the same fragment in its own block below.
    name: "pinkas/lib-syntax",
    files: ["lib/**/*.{ts,tsx,mts}"],
    ignores: ["lib/domain/**", "lib/data/portal.ts"],
    rules: {
      "no-restricted-syntax": ["error", ...serviceKeySyntax, ...portalUrlSyntax],
    },
  },
  {
    // The one file that may name PORTAL_DATABASE_URL. The service-key ban
    // still applies to it.
    name: "pinkas/portal-module-syntax",
    files: ["lib/data/portal.ts"],
    rules: {
      "no-restricted-syntax": ["error", ...serviceKeySyntax],
    },
  },

  {
    name: "pinkas/domain-is-pure",
    files: ["lib/domain/**/*.ts"],
    rules: {
      "no-restricted-syntax": [
        "error",
        ...noClockSyntax,
        ...serviceKeySyntax,
        ...portalUrlSyntax,
      ],
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [serviceRolePattern, userClientPattern, domainPurityPattern],
        },
      ],
    },
  },

  {
    name: "pinkas/portal-boundary",
    files: ["app/(portal)/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [
            serviceRolePattern,
            userClientPattern,
            portalCannotReachInstructorData,
          ],
        },
      ],
    },
  },
  {
    name: "pinkas/instructor-boundary",
    files: ["app/(instructor)/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          paths: supabaseClientPaths,
          patterns: [
            serviceRolePattern,
            userClientPattern,
            defineOutsidePattern,
            instructorCannotReachPortalData,
          ],
        },
      ],
    },
  },
]);

export default eslintConfig;
