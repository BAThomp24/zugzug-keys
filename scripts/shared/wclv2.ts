/**
 * WarcraftLogs V2 (GraphQL) data layer.
 *
 * Pulls detailed combatant info (including talents) via the `characterRankings`
 * query with `includeCombatantInfo: true`, for both raid bosses and M+ dungeons.
 * Used by the aggregation layer to cluster talent fingerprints into canonical
 * builds and surface live loadout export strings.
 */

import type {
  ClassConfig,
  GearHints,
  GearItemRef,
  HeroTreeSignatures,
  Role,
  TrinketPairing,
  EmbellishmentHint,
} from "./types.js";
import { EMBELLISHMENT_BONUS_IDS } from "./embellishments.js";

const WCL_TOKEN_URL = "https://www.warcraftlogs.com/oauth/token";
const WCL_V2_URL = "https://www.warcraftlogs.com/api/v2/client";

/** WCL difficulty ids for raid encounters. Normal (3) is intentionally skipped. */
export const RAID_DIFFICULTY_HEROIC = 4;
export const RAID_DIFFICULTY_MYTHIC = 5;

/** Milliseconds to wait between consecutive V2 requests within a worker's loop. */
const V2_REQUEST_DELAY_MS = 1100;
const V2_MAX_RETRIES = 4;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ─── OAuth2 ──────────────────────────────────────────────────────────────────

interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
}

export async function getV2Token(
  clientId: string,
  clientSecret: string,
): Promise<{ token: string; expiresIn: number }> {
  const body = new URLSearchParams({ grant_type: "client_credentials" });

  const response = await fetch(WCL_TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${clientId}:${clientSecret}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });

  if (!response.ok) {
    throw new Error(
      `V2 OAuth failed: ${response.status} ${response.statusText}`,
    );
  }

  const data = (await response.json()) as TokenResponse;
  return { token: data.access_token, expiresIn: data.expires_in };
}

// ─── GraphQL query ───────────────────────────────────────────────────────────

interface V2Talent {
  talentID: number;
  points: number;
}

interface V2CombatantInfo {
  specID: number;
  talents: V2Talent[];
  talentTree?: string;
}

interface V2GearItem {
  id: number;
  slot: number;
  name?: string;
  icon?: string;
  itemLevel?: number;
  bonusIDs?: number[];
  quality?: number;
}

interface V2RankingEntry {
  name: string;
  amount: number;
  talents?: V2Talent[];
  gear?: V2GearItem[];
  talentTree?: string;
  combatantInfo?: V2CombatantInfo;
  /** Mythic+ key level for dungeon rankings. */
  hardModeLevel?: number;
  bracketData?: number;
}

interface V2RankingsPayload {
  page: number;
  hasMorePages: boolean;
  count: number;
  rankings: V2RankingEntry[];
}

interface V2GraphQLResponse {
  data?: {
    worldData?: {
      encounter?: {
        characterRankings?: V2RankingsPayload;
      };
    };
  };
  errors?: Array<{ message: string }>;
}

/** Strip whitespace from a class/spec display name to produce the V2 form. */
function v2ClassName(name: string): string {
  return name.replace(/\s+/g, "");
}

function v2SpecName(name: string): string {
  return name.replace(/\s+/g, "");
}

/** Pages to pull per (class, spec, encounter, difficulty) query. Each WCL page
 *  is up to ~100 entries; higher numbers deepen the parse pool but multiply
 *  the per-refresh query count and rate-limit pressure. Realistic returns
 *  taper after page ~3 for niche specs. */
const V2_PAGES_PER_QUERY = 3;

/**
 * Per-refresh telemetry for the WCL v2 layer. Reset at the start of each cron
 * refresh and logged at the end so we can see total queries, rate-limit
 * retries, and wall-clock time — useful for tuning V2_PAGES_PER_QUERY.
 */
export const v2Stats = {
  queries: 0,
  retries429: 0,
  retries5xx: 0,
  totalFetchMs: 0,
};

export function resetV2Stats(): void {
  v2Stats.queries = 0;
  v2Stats.retries429 = 0;
  v2Stats.retries5xx = 0;
  v2Stats.totalFetchMs = 0;
}

export function reportV2Stats(): string {
  return `[v2] queries=${v2Stats.queries} retries429=${v2Stats.retries429} retries5xx=${v2Stats.retries5xx} fetchMs=${Math.round(v2Stats.totalFetchMs)}`;
}

/**
 * Query V2 for top character rankings with combatant info (talents).
 * Pulls up to V2_PAGES_PER_QUERY pages and concatenates them, bailing early
 * when WCL reports no more pages.
 */
async function queryCharacterRankings(
  token: string,
  encounterId: number,
  className: string,
  specName: string,
  metric: string,
  difficulty?: number,
): Promise<V2RankingEntry[]> {
  const diffArg =
    difficulty !== undefined ? `, difficulty: ${difficulty}` : "";
  const all: V2RankingEntry[] = [];

  for (let pageNum = 1; pageNum <= V2_PAGES_PER_QUERY; pageNum++) {
    const query = `{
      worldData {
        encounter(id: ${encounterId}) {
          characterRankings(
            className: "${v2ClassName(className)}"
            specName: "${v2SpecName(specName)}"
            metric: ${metric}
            includeCombatantInfo: true
            page: ${pageNum}
            ${diffArg}
          )
        }
      }
    }`;

    let response: Response | undefined;
    for (let attempt = 0; attempt <= V2_MAX_RETRIES; attempt++) {
      const fetchStart = Date.now();
      response = await fetch(WCL_V2_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query }),
      });
      v2Stats.totalFetchMs += Date.now() - fetchStart;
      v2Stats.queries++;

      if (response.status === 429 && attempt < V2_MAX_RETRIES) {
        v2Stats.retries429++;
        const backoff = (attempt + 1) * 5000;
        console.warn(`V2 rate limited (429), backing off ${backoff}ms (attempt ${attempt + 1}/${V2_MAX_RETRIES})...`);
        await sleep(backoff);
        continue;
      }
      if (response.status >= 500 && attempt < V2_MAX_RETRIES) {
        v2Stats.retries5xx++;
        const backoff = (attempt + 1) * 1500;
        console.warn(`V2 server error ${response.status}, retrying in ${backoff}ms...`);
        await sleep(backoff);
        continue;
      }
      break;
    }

    if (!response || !response.ok) {
      throw new Error(
        `V2 GraphQL failed: ${response?.status} ${response?.statusText}`,
      );
    }

    const result = (await response.json()) as V2GraphQLResponse;

    if (result.errors?.length) {
      throw new Error(
        `V2 GraphQL errors: ${result.errors.map((e) => e.message).join("; ")}`,
      );
    }

    const payload = result.data?.worldData?.encounter?.characterRankings;
    const rankings = payload?.rankings ?? [];
    all.push(...rankings);

    // Stop paginating as soon as WCL signals there's nothing more or the page
    // came back empty — saves queries for the long tail of niche specs.
    if (!payload?.hasMorePages || rankings.length === 0) break;
  }

  return all;
}

// ─── Hero tree detection ─────────────────────────────────────────────────────

function classifyHeroTree(
  talents: V2Talent[],
  signatures: HeroTreeSignatures,
): string | null {
  // Hero-tree signatures must match actually-spent talents, so we filter out
  // any `points: 0` entries (unselected choice-node residue).
  const talentIds = new Set(
    talents.filter((t) => t.points > 0).map((t) => t.talentID),
  );
  let bestTree: string | null = null;
  let bestCount = 0;

  for (const [treeName, sigIds] of Object.entries(signatures)) {
    const matches = sigIds.filter((id) => talentIds.has(id)).length;
    if (matches > bestCount) {
      bestCount = matches;
      bestTree = treeName;
    }
  }

  return bestCount >= 1 ? bestTree : null;
}

// ─── Loadout export extraction ───────────────────────────────────────────────

function looksLikeLoadoutCode(value: unknown): value is string {
  // WoW talent export strings are base64 or base64url encoded.
  // Accept both: standard (+, /) and URL-safe (-, _) variants.
  return (
    typeof value === "string" &&
    value.length >= 60 &&
    /^[A-Za-z0-9+/=\-_]+$/.test(value) &&
    !/\s/.test(value) // no whitespace
  );
}

const LOADOUT_FIELDS = [
  "talentLoadoutCode", // TWW+ WCL field name
  "talentTree",
  "talentExport",
  "talentLoadout",
  "loadout",
  "loadoutExport",
  "talentString",
  "exportString",
] as const;

function getImportCode(entry: V2RankingEntry): string | null {
  const entryObj = entry as unknown as Record<string, unknown>;
  const ciRaw = entryObj["combatantInfo"];

  // combatantInfo may arrive as a pre-parsed object OR as a JSON string — handle both.
  let ciObj: Record<string, unknown> = {};
  if (ciRaw && typeof ciRaw === "object") {
    ciObj = ciRaw as Record<string, unknown>;
  } else if (typeof ciRaw === "string") {
    // If it's the export string itself, looksLikeLoadoutCode will catch it below.
    try { ciObj = JSON.parse(ciRaw) as Record<string, unknown>; } catch { /* ignore */ }
  }

  const bag: Record<string, unknown> = { ...entryObj, ...ciObj };

  // Named-field fast path.
  for (const field of LOADOUT_FIELDS) {
    const value = bag[field];
    if (looksLikeLoadoutCode(value)) return value;
  }

  // Full scan: top-level values.
  for (const value of Object.values(bag)) {
    if (looksLikeLoadoutCode(value)) return value;
  }

  // One level deeper — scan values of every nested object (e.g. talentData.exportString).
  for (const value of Object.values(bag)) {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const nested of Object.values(value as Record<string, unknown>)) {
        if (looksLikeLoadoutCode(nested)) return nested;
      }
    }
  }

  return null;
}

let loggedMissingImportSample = false;

function logMissingImportSample(
  className: string,
  specName: string,
  entry: V2RankingEntry,
): void {
  if (loggedMissingImportSample) return;
  loggedMissingImportSample = true;
  const entryObj = entry as unknown as Record<string, unknown>;
  const ciRaw = entryObj["combatantInfo"];
  const topKeys = Object.keys(entryObj);
  // Log a full JSON sample of combatantInfo so we can see what WCL actually sends.
  console.warn(
    `[wclv2] no import extracted for ${className}/${specName}. entry keys=${topKeys.join(",")} combatantInfo=${JSON.stringify(ciRaw)?.slice(0, 500)}`,
  );
}

// ─── Shared enriched ranking shape (raid + M+) ──────────────────────────────

/** A single V2 ranking enriched with a talent fingerprint + detected hero tree. */
export interface V2Ranking {
  /** Spec name (from the query that produced this ranking). */
  spec: string;
  /** Score returned by V2 (`amount` — dps or hps). */
  amount: number;
  /** Sorted+joined talent IDs — a stable identity for a player's build. */
  fingerprint: string;
  /** Hero tree detected from signature talents, or "" when unknown. */
  hero: string;
  /** Raw talent IDs (in case the caller wants to re-classify). */
  talentIds: number[];
  /** Live talent loadout import string, or "" if unavailable. */
  importString: string;
  /** Mythic+ key level for dungeon rankings (0 for raid). */
  keystoneLevel: number;
}

function metricForRole(role: Role): string {
  return role === "healer" ? "hps" : "dps";
}

function specIdsForRole(config: ClassConfig, role: Role): number[] {
  if (role === "healer") return config.healerSpecIds ?? [];
  if (role === "tank") return config.tankSpecIds ?? [];
  return config.dpsSpecIds;
}

/**
 * Expand V2 talents into one entry per point spent. WCL's V2 returns each
 * talent as `{ talentID, points }`; choice-node "loser" entries arrive with
 * `points: 0` and have to be dropped, and multi-rank talents need to be
 * counted by their rank (so the resulting array length equals total points
 * spent — exactly 81 for any max-level WoW Midnight character). Both the
 * fingerprint and the persisted `talentIds` use this expansion so anywhere
 * downstream that counts entries is counting points, not spurious choice-
 * node residue.
 */
function expandTalentPoints(talents: V2Talent[]): number[] {
  const out: number[] = [];
  for (const t of talents) {
    if (!t || t.points <= 0) continue;
    for (let i = 0; i < t.points; i++) out.push(t.talentID);
  }
  return out;
}

function fingerprintOf(talents: V2Talent[]): string {
  return expandTalentPoints(talents)
    .sort((a, b) => a - b)
    .join(",");
}

function classifyTreeWithFallback(
  talents: V2Talent[],
  signatures: HeroTreeSignatures | undefined,
): string {
  if (!signatures) return "";
  return classifyHeroTree(talents, signatures) ?? "";
}

function enrichEntry(
  entry: V2RankingEntry,
  specName: string,
  signatures: HeroTreeSignatures | undefined,
  className: string,
): V2Ranking | null {
  const talents = entry.talents ?? entry.combatantInfo?.talents ?? [];
  if (talents.length === 0) return null;
  // Use the points-expanded form so talentIds.length always equals total
  // talent points spent (81 at max level) instead of leaking unselected
  // choice-node entries or under-counting multi-rank talents.
  const talentIds = expandTalentPoints(talents);
  const importString = getImportCode(entry) ?? "";
  if (!importString) logMissingImportSample(className, specName, entry);
  return {
    spec: specName,
    amount: entry.amount,
    fingerprint: fingerprintOf(talents),
    hero: classifyTreeWithFallback(talents, signatures),
    talentIds,
    importString,
    keystoneLevel: entry.hardModeLevel ?? entry.bracketData ?? 0,
  };
}

/**
 * Pull M+ dungeon rankings for all role specs of a single class. For each
 * (spec, dungeon) pair this makes one V2 query and returns ~100 enriched entries.
 */
export async function pullMpDungeonRankings(
  token: string,
  className: string,
  config: ClassConfig,
  role: Role,
  dungeons: readonly { id: number; name: string }[],
): Promise<{ result: Record<string, V2Ranking[]>; failures: number }> {
  const metric = metricForRole(role);
  const specIds = specIdsForRole(config, role);
  const result: Record<string, V2Ranking[]> = {};
  for (const d of dungeons) result[d.name] = [];
  let failures = 0;

  let isFirst = true;
  for (const specId of specIds) {
    const specName = config.specs[specId];
    if (!specName) continue;
    const signatures = config.heroTrees?.[specName];
    for (const dungeon of dungeons) {
      try {
        if (!isFirst) await sleep(V2_REQUEST_DELAY_MS);
        isFirst = false;
        const rankings = await queryCharacterRankings(
          token,
          dungeon.id,
          className,
          specName,
          metric,
        );
        for (const entry of rankings) {
          const enriched = enrichEntry(entry, specName, signatures, className);
          if (enriched) result[dungeon.name]!.push(enriched);
        }
      } catch (err) {
        failures++;
        console.error(
          `[${className}/${specName}] V2 M+ ${dungeon.name} failed:`,
          err,
        );
      }
    }
  }

  return { result, failures };
}

/**
 * Pull raid boss rankings for all role specs of a single class, across both
 * Heroic and Mythic difficulty. Returns a nested map keyed by boss name and
 * difficulty so the caller can compute canonical builds + per-boss counts.
 */
export async function pullRaidBossRankings(
  token: string,
  className: string,
  config: ClassConfig,
  role: Role,
  bosses: readonly { id: number; name: string }[],
): Promise<{ result: Record<string, Record<"heroic" | "mythic", V2Ranking[]>>; failures: number }> {
  const metric = metricForRole(role);
  const specIds = specIdsForRole(config, role);
  const result: Record<string, Record<"heroic" | "mythic", V2Ranking[]>> = {};
  for (const b of bosses) {
    result[b.name] = { heroic: [], mythic: [] };
  }
  let failures = 0;

  const difficulties: { name: "heroic" | "mythic"; id: number }[] = [
    { name: "heroic", id: RAID_DIFFICULTY_HEROIC },
    { name: "mythic", id: RAID_DIFFICULTY_MYTHIC },
  ];

  let isFirst = true;
  for (const specId of specIds) {
    const specName = config.specs[specId];
    if (!specName) continue;
    const signatures = config.heroTrees?.[specName];
    for (const difficulty of difficulties) {
      for (const boss of bosses) {
        try {
          if (!isFirst) await sleep(V2_REQUEST_DELAY_MS);
          isFirst = false;
          const rankings = await queryCharacterRankings(
            token,
            boss.id,
            className,
            specName,
            metric,
            difficulty.id,
          );
          for (const entry of rankings) {
            const enriched = enrichEntry(entry, specName, signatures, className);
            if (enriched) result[boss.name]![difficulty.name].push(enriched);
          }
        } catch (err) {
          failures++;
          console.error(
            `[${className}/${specName}] V2 raid ${boss.name}/${difficulty.name} failed:`,
            err,
          );
        }
      }
    }
  }

  return { result, failures };
}

// ─── Gear hint extraction ─────────────────────────────────────────────────────

// WCL gear slot field is 0-indexed array position: trinket1=12, trinket2=13.
const TRINKET_SLOTS = new Set([12, 13]);

function extractGearFromEntry(entry: V2RankingEntry): V2GearItem[] {
  const ci = entry.combatantInfo as unknown as Record<string, unknown> | undefined;
  const raw: unknown[] | undefined =
    Array.isArray(entry.gear) && entry.gear.length > 0
      ? entry.gear
      : Array.isArray(ci?.["gear"])
        ? (ci!["gear"] as unknown[])
        : undefined;
  if (!raw) return [];
  // WCL does not populate the slot field — use array index as the slot.
  return raw.map((item, i) => {
    const g = item as V2GearItem;
    return g.slot !== undefined ? g : { ...g, slot: i };
  });
}

export function computeGearHints(
  encounterRankings: [string, V2RankingEntry[]][],
): GearHints {
  const SAMPLE_PER_ENCOUNTER = 20;
  const encounterNames = encounterRankings.map(([name]) => name);
  const allEntries = encounterRankings.flatMap(([, rankings]) =>
    rankings.slice(0, SAMPLE_PER_ENCOUNTER),
  );

  const trinketPairCounts = new Map<string, { count: number; pair: [GearItemRef, GearItemRef] }>();
  const embellishmentCounts = new Map<string, { count: number; hint: EmbellishmentHint }>();
  let sampleSize = 0;

  for (const entry of allEntries) {
    const gear = extractGearFromEntry(entry);
    if (gear.length === 0) continue;
    sampleSize++;

    const trinkets = gear
      .filter((g) => TRINKET_SLOTS.has(g.slot) && g.id)
      .map((g) => ({ itemId: g.id, name: g.name ?? `Item #${g.id}`, icon: g.icon } satisfies GearItemRef))
      .sort((a, b) => a.itemId - b.itemId);

    if (trinkets.length === 2) {
      const pairKey = `${trinkets[0]!.itemId}:${trinkets[1]!.itemId}`;
      const existing = trinketPairCounts.get(pairKey);
      if (existing) {
        existing.count++;
      } else {
        trinketPairCounts.set(pairKey, { count: 1, pair: [trinkets[0]!, trinkets[1]!] });
      }
    }

    const seen = new Set<string>();
    for (const item of gear) {
      for (const bonusId of item.bonusIDs ?? []) {
        const emblName = EMBELLISHMENT_BONUS_IDS[bonusId];
        if (!emblName || seen.has(emblName)) continue;
        seen.add(emblName);
        const existing = embellishmentCounts.get(emblName);
        if (existing) {
          existing.count++;
        } else {
          embellishmentCounts.set(emblName, { count: 1, hint: { name: emblName, itemId: item.id, usagePct: 0 } });
        }
      }
    }
  }

  const topTrinketPairs: TrinketPairing[] = [...trinketPairCounts.values()]
    .sort((a, b) => b.count - a.count)
    .slice(0, 3)
    .map(({ count, pair }) => ({ trinkets: pair, usagePct: sampleSize > 0 ? Math.round((count / sampleSize) * 100) : 0 }));

  const topEmbellishments: EmbellishmentHint[] = [...embellishmentCounts.values()]
    .sort((a, b) => b.count - a.count)
    .slice(0, 3)
    .map(({ count, hint }) => ({ ...hint, usagePct: sampleSize > 0 ? Math.round((count / sampleSize) * 100) : 0 }));

  return { sampleSize, topTrinketPairs, topEmbellishments, sampledFromEncounters: encounterNames };
}

export async function pullGearHintsForClass(
  token: string,
  className: string,
  config: ClassConfig,
  encounters: readonly { id: number; name: string }[],
  difficulty?: number,
): Promise<{ result: Record<string, GearHints>; failures: number }> {
  if (encounters.length === 0) return { result: {}, failures: 0 };

  const diffArg = difficulty !== undefined ? `, difficulty: ${difficulty}` : "";

  // Collect unique specs with their metrics
  const allSpecIds = [
    ...config.dpsSpecIds,
    ...(config.healerSpecIds ?? []),
    ...(config.tankSpecIds ?? []),
  ];
  const specs: { name: string; metric: string }[] = [];
  const seenSpecs = new Set<string>();
  for (const specId of allSpecIds) {
    const specName = config.specs[specId];
    if (!specName || seenSpecs.has(specName)) continue;
    seenSpecs.add(specName);
    const isHealer = (config.healerSpecIds ?? []).includes(specId);
    specs.push({ name: specName, metric: isHealer ? "hps" : "dps" });
  }
  if (specs.length === 0) return { result: {}, failures: 0 };

  // One request batches all encounters × all specs via GraphQL aliases:
  // s0_e0: encounter(id:...) { characterRankings(className:... specName:...) }
  const aliases = specs.flatMap((spec, si) =>
    encounters.map((enc, ei) => {
      const args = `className: "${v2ClassName(className)}" specName: "${v2SpecName(spec.name)}" metric: ${spec.metric} includeCombatantInfo: true page: 1${diffArg}`;
      return `s${si}_e${ei}: encounter(id: ${enc.id}) { characterRankings(${args}) }`;
    }),
  ).join("\n    ");
  const query = `{ worldData {\n    ${aliases}\n  } }`;

  let response: Response | undefined;
  for (let attempt = 0; attempt <= V2_MAX_RETRIES; attempt++) {
    response = await fetch(WCL_V2_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });
    if (response.status === 429 && attempt < V2_MAX_RETRIES) { await sleep((attempt + 1) * 5000); continue; }
    if (response.status >= 500 && attempt < V2_MAX_RETRIES) { await sleep((attempt + 1) * 1500); continue; }
    break;
  }

  if (!response || !response.ok) return { result: {}, failures: 1 };

  const json = (await response.json()) as {
    data?: { worldData?: Record<string, { characterRankings?: V2RankingsPayload }> };
    errors?: Array<{ message: string }>;
  };

  if (json.errors?.length) {
    console.warn(`[gear] GraphQL errors for ${className}: ${json.errors.map((e) => e.message).join("; ")}`);
    return { result: {}, failures: 1 };
  }

  const worldData = json.data?.worldData ?? {};
  const result: Record<string, GearHints> = {};

  for (let si = 0; si < specs.length; si++) {
    const spec = specs[si]!;
    const encounterRankings: [string, V2RankingEntry[]][] = encounters.map((enc, ei) => {
      const payload = worldData[`s${si}_e${ei}`];
      return [enc.name, payload?.characterRankings?.rankings ?? []];
    });
    if (encounterRankings.some(([, r]) => r.length > 0)) {
      result[spec.name] = computeGearHints(encounterRankings);
    }
  }

  return { result, failures: 0 };
}
