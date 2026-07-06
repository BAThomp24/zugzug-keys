/**
 * WCL-derived lust calls: where do the top M+ groups actually cast
 * Bloodlust/Heroism/Time Warp per dungeon?
 *
 * Pipeline (weekly):
 *   1. fightRankings per dungeon → top runs' report codes + fight IDs.
 *   2. Per run, one report query → the run fight's dungeonPulls timeline
 *      (pulls carry kill=true for boss pulls + the boss NAME) and all lust
 *      cast events (filterExpression on the lust spell IDs).
 *   3. Each cast is classified into a ROUTE-TRANSFERABLE descriptor:
 *        { type: "boss", bossName }                        — cast during a boss pull
 *        { type: "afterBoss", anchorBossName|null, pullOffset } — Nth trash pack
 *          after that boss (null anchor = Nth pack from the run start).
 *   4. Consensus across runs (dedupe per run, keep calls in ≥ minSupport of
 *      runs, cap depth + count) → KV blob → /api/lust-calls → the ZugZugKeys
 *      generator regenerates LustDataWCL.lua.
 *
 * Shapes verified against live WCL v2 on 2026-07-02 (report 4vF39AdTJn2KVRCW):
 *   fightRankings → { rankings: [{ report: { code, fightID }, bracketData, ... }] }
 *   fights(fightIDs) → [{ startTime, endTime, keystoneLevel,
 *                         dungeonPulls: [{ name, startTime, endTime, kill }] }]
 *   events(dataType: Casts, filterExpression) → { data: [{ timestamp,
 *                         abilityGameID, type: "cast", ... }] }
 */

import { DUNGEONS } from "./encounters.js";
import { getV2Token } from "./wclv2.js";
import type { ZugzugKV } from "./kv.js";

const WCL_V2_URL = "https://www.warcraftlogs.com/api/v2/client";

/** Spell IDs that count as a lust cast. */
export const LUST_SPELL_IDS = [
  2825,   // Bloodlust
  32182,  // Heroism
  80353,  // Time Warp
  390386, // Fury of the Aspects
  264667, // Primal Rage (hunter pet)
] as const;

// ─── Types ───────────────────────────────────────────────────────────────────

export interface WclPull {
  name: string;
  startTime: number;
  endTime: number;
  kill: boolean;
}

/** A single route-transferable lust call descriptor. */
export type LustCallDescriptor =
  | { type: "boss"; bossName: string }
  | { type: "afterBoss"; anchorBossName: string | null; pullOffset: number };

/** A consensus call for one dungeon, with how many analyzed runs agreed. */
export interface LustCall {
  type: "boss" | "afterBoss";
  bossName?: string;
  anchorBossName?: string | null;
  pullOffset?: number;
  /** Runs containing this call / runs analyzed. */
  support: number;
  runsAnalyzed: number;
  /** Median cast time as a 0-1 fraction of run duration — ordering only. */
  medianAt: number;
  /** Median cast time in ms from run start — places timer-bar ticks in the
   *  addon. 0 when the source runs carried no absolute times. */
  medianAtMs: number;
}

export interface DungeonLustCalls {
  dungeonName: string;
  runsAnalyzed: number;
  keystoneLevels: number[];
  calls: LustCall[];
  /** Alternate leaderboard cohorts, same shape minus this field: p1 ≈ the
   *  top-1% bracket, p01 ≈ the low end of the top-0.1% bracket. The parent
   *  entry itself is the "top" (rank 1-N) cohort. */
  cohorts?: Partial<Record<"p1" | "p01", Omit<DungeonLustCalls, "cohorts">>>;
}

export interface LustCallsBlob {
  generatedAt: string;
  dungeons: DungeonLustCalls[];
}

// ─── Pure classification + consensus (unit-tested) ───────────────────────────

/**
 * Classify one lust cast against the run's pull timeline. Casts landing in
 * downtime attach to the NEXT pull (lust is often pressed as the pull is
 * being set up). Returns null when the cast can't be attributed.
 */
export function classifyCast(
  timestamp: number,
  pulls: WclPull[],
): LustCallDescriptor | null {
  const sorted = pulls.slice().sort((a, b) => a.startTime - b.startTime);
  let pull = sorted.find((p) => timestamp >= p.startTime && timestamp <= p.endTime);
  pull ??= sorted.find((p) => p.startTime > timestamp);
  if (!pull) return null;

  if (pull.kill) return { type: "boss", bossName: pull.name };

  // Anchor: the last boss pull fully ended before this trash pull started.
  let anchor: WclPull | null = null;
  for (const p of sorted) {
    if (p.kill && p.endTime <= pull.startTime) anchor = p;
  }
  const anchorEnd = anchor ? anchor.endTime : -Infinity;
  let offset = 0;
  for (const p of sorted) {
    if (!p.kill && p.startTime > anchorEnd && p.startTime <= pull.startTime) offset++;
  }
  return {
    type: "afterBoss",
    anchorBossName: anchor ? anchor.name : null,
    pullOffset: Math.max(1, offset),
  };
}

function descriptorKey(d: LustCallDescriptor): string {
  return d.type === "boss"
    ? `boss:${d.bossName.toLowerCase()}`
    : `after:${(d.anchorBossName ?? "<start>").toLowerCase()}:${d.pullOffset}`;
}

export interface RunCalls {
  keystoneLevel: number;
  /** Descriptor + cast time as fraction of run duration (at) and as
   *  absolute ms from run start (atMs; optional for older fixtures). */
  calls: { descriptor: LustCallDescriptor; at: number; atMs?: number }[];
}

/**
 * Consensus across runs: dedupe within each run, keep descriptors present in
 * ≥ minSupport of runs, drop trash calls deeper than maxDepth packs, order by
 * median cast position, cap at maxCalls.
 */
export function consensusCalls(
  runs: RunCalls[],
  opts: { minSupport?: number; maxDepth?: number; maxCalls?: number } = {},
): LustCall[] {
  const minSupport = opts.minSupport ?? 0.5;
  const maxDepth = opts.maxDepth ?? 3;
  const maxCalls = opts.maxCalls ?? 4;
  if (runs.length === 0) return [];

  const byKey = new Map<
    string,
    { descriptor: LustCallDescriptor; ats: number[]; atsMs: number[]; runsWith: number }
  >();
  for (const run of runs) {
    const seenThisRun = new Set<string>();
    for (const { descriptor, at, atMs } of run.calls) {
      if (descriptor.type === "afterBoss" && descriptor.pullOffset > maxDepth) continue;
      const key = descriptorKey(descriptor);
      let entry = byKey.get(key);
      if (!entry) {
        entry = { descriptor, ats: [], atsMs: [], runsWith: 0 };
        byKey.set(key, entry);
      }
      entry.ats.push(at);
      if (typeof atMs === "number") entry.atsMs.push(atMs);
      if (!seenThisRun.has(key)) {
        seenThisRun.add(key);
        entry.runsWith++;
      }
    }
  }

  const total = runs.length;
  const kept: LustCall[] = [];
  for (const { descriptor, ats, atsMs, runsWith } of byKey.values()) {
    if (runsWith / total < minSupport) continue;
    const sortedAts = ats.slice().sort((a, b) => a - b);
    const medianAt = sortedAts[Math.floor(sortedAts.length / 2)] ?? 0;
    const sortedMs = atsMs.slice().sort((a, b) => a - b);
    const medianAtMs = Math.round(sortedMs[Math.floor(sortedMs.length / 2)] ?? 0);
    kept.push({
      type: descriptor.type,
      bossName: descriptor.type === "boss" ? descriptor.bossName : undefined,
      anchorBossName: descriptor.type === "afterBoss" ? descriptor.anchorBossName : undefined,
      pullOffset: descriptor.type === "afterBoss" ? descriptor.pullOffset : undefined,
      support: runsWith,
      runsAnalyzed: total,
      medianAt,
      medianAtMs,
    });
  }
  kept.sort((a, b) => a.medianAt - b.medianAt);
  return kept.slice(0, maxCalls);
}

// ─── WCL fetch layer ─────────────────────────────────────────────────────────

// WCL enforces an hourly points budget AND a burst per-IP throttle — ~230
// unpaced requests inside two minutes trips the latter (observed live
// 2026-07-04 from the worker's Cloudflare egress). Pace every call and
// back off + retry when a 429 slips through anyway.
const WCL_PACE_MS = 500;
const WCL_429_BACKOFF_MS = 65_000;
const WCL_429_RETRIES = 2;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function wclFetch(token: string, query: string): Promise<Response> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(WCL_V2_URL, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ query }),
    });
    if (res.status === 429 && attempt < WCL_429_RETRIES) {
      console.warn(`[wcl] 429 — backing off ${WCL_429_BACKOFF_MS / 1000}s (attempt ${attempt + 1})`);
      await sleep(WCL_429_BACKOFF_MS);
      continue;
    }
    await sleep(WCL_PACE_MS);
    return res;
  }
}

async function wclQuery(token: string, query: string): Promise<unknown> {
  const res = await wclFetch(token, query);
  if (!res.ok) throw new Error(`WCL query failed: ${res.status}`);
  const json = (await res.json()) as { data?: unknown; errors?: { message: string }[] };
  if (json.errors?.length) throw new Error(`WCL GraphQL: ${json.errors[0]!.message}`);
  return json.data;
}

/** Like wclQuery, but tolerates per-alias errors (a private report inside a
 *  batched query errors its alias to null without failing the siblings). */
async function wclQueryLenient(
  token: string,
  query: string,
): Promise<{ data: unknown; errors: string[] }> {
  const res = await wclFetch(token, query);
  if (!res.ok) throw new Error(`WCL query failed: ${res.status}`);
  const json = (await res.json()) as { data?: unknown; errors?: { message: string }[] };
  return { data: json.data, errors: (json.errors ?? []).map((e) => e.message) };
}

interface FightRankingEntry {
  report?: { code?: string; fightID?: number };
  bracketData?: number;
}

export type LustCohort = "top" | "p1" | "p01";

/** Every cohort a sweep derives. "top" = rank 1-N; "p1" ≈ the top-1%
 *  bracket; "p01" ≈ the low end of the top-0.1% bracket. The rank-1 runs
 *  tend to be degenerate routes most groups never replicate, so the
 *  percentile cohorts are elite-but-standard route sources. */
export const LUST_COHORTS: readonly LustCohort[] = ["top", "p1", "p01"];

interface RankingsPage {
  entries: { code: string; fightID: number; keystoneLevel: number }[];
  hasMorePages: boolean;
}

/** One fightRankings page (50 entries). `bracket` filters to a single
 *  keystone level: bracket index b returns exactly key level b+1
 *  (verified live 2026-07-04; the API exposes no population total and
 *  unfiltered paging caps around rank ~1000-2400). */
async function fetchRankingsPage(
  token: string,
  dungeonId: number,
  page: number,
  bracket?: number,
): Promise<RankingsPage> {
  const args = `page: ${page}${bracket !== undefined ? `, bracket: ${bracket}` : ""}`;
  const data = (await wclQuery(
    token,
    `{ worldData { encounter(id: ${dungeonId}) { fightRankings(${args}) } } }`,
  )) as {
    worldData?: {
      encounter?: {
        fightRankings?: { rankings?: FightRankingEntry[]; hasMorePages?: boolean };
      };
    };
  };
  const fr = data?.worldData?.encounter?.fightRankings;
  const entries: RankingsPage["entries"] = [];
  for (const r of fr?.rankings ?? []) {
    const code = r.report?.code;
    const fightID = r.report?.fightID;
    if (typeof code !== "string" || typeof fightID !== "number") continue;
    entries.push({ code, fightID, keystoneLevel: r.bracketData ?? 0 });
  }
  return { entries, hasMorePages: fr?.hasMorePages === true };
}

/** Dedupe by report code — the same premade often owns several slots. */
function takeUniqueRuns(
  entries: RankingsPage["entries"],
  startIndex: number,
  count: number,
): { code: string; fightID: number; keystoneLevel: number }[] {
  const out: RankingsPage["entries"] = [];
  const seen = new Set<string>();
  for (let i = Math.max(0, startIndex); i < entries.length && out.length < count; i++) {
    const e = entries[i]!;
    if (seen.has(e.code)) continue;
    seen.add(e.code);
    out.push(e);
  }
  return out;
}

// Cohorts are keystone-level anchored. The API exposes no population total
// (its `count` field is just the page size) and unfiltered paging caps
// around rank ~1000-2400, so true population percentiles aren't computable
// — but key levels map cleanly onto the intent: the record runs sit at
// maxKey ("top"), the low end of the top-0.1% crowd runs maxKey-1, and the
// ~1% crowd runs maxKey-2.
const COHORT_KEY_OFFSET: Record<Exclude<LustCohort, "top">, number> = {
  p01: 1,
  p1: 2,
};
// Cap how many bracket pages (50 runs each) one cohort may walk.
const MAX_COHORT_PAGES = 4;

/** Runs for one dungeon + cohort. `page1` (unfiltered) is passed in when
 *  already fetched — it serves the "top" cohort AND tells us the current
 *  record key level that anchors the bracket cohorts. Bracket cohorts skip
 *  their bracket's first page (the fastest runs AT a level are that
 *  bracket's own record-chasers) and collect from page 2 onward; the
 *  skipped page pads the tail only if the bracket is thin. */
async function fetchCohortRuns(
  token: string,
  dungeonId: number,
  count: number,
  cohort: LustCohort,
  page1: RankingsPage,
): Promise<{ code: string; fightID: number; keystoneLevel: number }[]> {
  if (cohort === "top") return takeUniqueRuns(page1.entries, 0, count);

  const out: { code: string; fightID: number; keystoneLevel: number }[] = [];
  const seen = new Set<string>();
  const collect = (entries: RankingsPage["entries"]) => {
    for (const e of entries) {
      if (out.length >= count) return;
      if (seen.has(e.code)) continue;
      seen.add(e.code);
      out.push(e);
    }
  };

  const maxKey = page1.entries[0]?.keystoneLevel ?? 0;
  const targetLevel = maxKey - COHORT_KEY_OFFSET[cohort];
  if (targetLevel >= 2) {
    const bracket = targetLevel - 1; // bracket index b = key level b+1
    let firstBracketPage: RankingsPage["entries"] | null = null;
    for (let pageNo = 1; pageNo <= 1 + MAX_COHORT_PAGES && out.length < count; pageNo++) {
      const page = await fetchRankingsPage(token, dungeonId, pageNo, bracket);
      if (page.entries.length === 0) break;
      // Semantics guard: if the bracket filter ever stops meaning "exactly
      // key level b+1", drop everything collected and use the unfiltered
      // fallback below rather than mislabeling the cohort.
      if (page.entries.some((e) => e.keystoneLevel !== targetLevel)) {
        out.length = 0;
        break;
      }
      if (pageNo === 1) {
        firstBracketPage = page.entries; // record-chasers — tail padding only
      } else {
        collect(page.entries);
      }
      if (!page.hasMorePages) break;
    }
    if (out.length < count && firstBracketPage) collect(firstBracketPage);
  }
  if (out.length > 0) return out;

  // Fallback (thin/missing brackets, or the guard tripped): sample the
  // unfiltered leaderboard past the record runs — pages 2+ then page 1 tail.
  for (let pageNo = 2; pageNo <= MAX_COHORT_PAGES && out.length < count; pageNo++) {
    const page = await fetchRankingsPage(token, dungeonId, pageNo);
    if (page.entries.length === 0) break;
    collect(page.entries);
    if (!page.hasMorePages) break;
  }
  if (out.length === 0) {
    return takeUniqueRuns(page1.entries, Math.max(0, page1.entries.length - count * 2), count);
  }
  return out;
}

/** Top runs (report code + fightID + key level) for one dungeon — kept for
 *  probeLustDungeon and back-compat callers. */
export async function fetchTopRuns(
  token: string,
  dungeonId: number,
  count: number,
): Promise<{ code: string; fightID: number; keystoneLevel: number }[]> {
  const page1 = await fetchRankingsPage(token, dungeonId, 1);
  return takeUniqueRuns(page1.entries, 0, count);
}

interface ReportRunData {
  runFight?: { startTime?: number; endTime?: number; keystoneLevel?: number; dungeonPulls?: WclPull[] }[];
  events?: { data?: { timestamp?: number; abilityGameID?: number; type?: string }[] };
}

/** Shared parse: one report's fight + lust events → classified RunCalls. */
function parseRunData(report: ReportRunData | undefined, fallbackKeyLevel: number): RunCalls | null {
  const run = report?.runFight?.[0];
  const pulls = (run?.dungeonPulls ?? []).filter(
    (p): p is WclPull =>
      typeof p?.name === "string" &&
      typeof p?.startTime === "number" &&
      typeof p?.endTime === "number",
  );
  if (!run || pulls.length === 0) return null;

  const runStart = run.startTime ?? pulls[0]!.startTime;
  const runEnd = run.endTime ?? pulls[pulls.length - 1]!.endTime;
  const duration = Math.max(1, runEnd - runStart);

  const calls: RunCalls["calls"] = [];
  for (const ev of report?.events?.data ?? []) {
    if (typeof ev?.timestamp !== "number") continue;
    const descriptor = classifyCast(ev.timestamp, pulls);
    if (descriptor) {
      calls.push({
        descriptor,
        at: (ev.timestamp - runStart) / duration,
        atMs: ev.timestamp - runStart,
      });
    }
  }
  return { keystoneLevel: run.keystoneLevel ?? fallbackKeyLevel, calls };
}

const RUN_FIELDS = `
  runFight: fights(fightIDs: [%FID%]) {
    startTime endTime keystoneLevel
    dungeonPulls { name startTime endTime kill }
  }
  events(fightIDs: [%FID%], dataType: Casts, filterExpression: "%FILTER%", limit: 300) {
    data
  }`;

function runFields(fightID: number): string {
  const filter = `ability.id in (${LUST_SPELL_IDS.join(", ")})`;
  return RUN_FIELDS.replaceAll("%FID%", String(fightID)).replaceAll("%FILTER%", filter);
}

/** Pull timeline + lust casts for one run, classified into descriptors. */
export async function fetchRunCalls(
  token: string,
  code: string,
  fightID: number,
  keystoneLevel: number,
): Promise<RunCalls | null> {
  const data = (await wclQuery(
    token,
    `{ reportData { report(code: "${code}") { ${runFields(fightID)} } } }`,
  )) as { reportData?: { report?: ReportRunData } };
  return parseRunData(data?.reportData?.report, keystoneLevel);
}

// Reports batched per HTTP request via GraphQL aliases: the Workers runtime
// caps subrequests (not query size), and WCL points scale with complexity
// either way — so 10 reports per request turns a 100-run cohort into 10
// subrequests instead of 100.
const RUN_BATCH_SIZE = 10;

/** Fetch + parse many runs, batched. Per-alias failures (private/deleted
 *  reports) are logged and skipped without failing their batch. */
export async function fetchRunCallsBatch(
  token: string,
  runs: readonly { code: string; fightID: number; keystoneLevel: number }[],
  label: string,
): Promise<RunCalls[]> {
  const out: RunCalls[] = [];
  for (let start = 0; start < runs.length; start += RUN_BATCH_SIZE) {
    const chunk = runs.slice(start, start + RUN_BATCH_SIZE);
    const aliases = chunk
      .map((r, i) => `r${i}: report(code: "${r.code}") { ${runFields(r.fightID)} }`)
      .join("\n");
    try {
      const { data, errors } = await wclQueryLenient(token, `{ reportData { ${aliases} } }`);
      if (errors.length) {
        console.warn(`[lust-calls] ${label}: ${errors.length} report(s) skipped in batch (${errors[0]})`);
      }
      const reports = (data as { reportData?: Record<string, ReportRunData | undefined> })?.reportData;
      chunk.forEach((r, i) => {
        const parsed = parseRunData(reports?.[`r${i}`], r.keystoneLevel);
        if (parsed) out.push(parsed);
      });
    } catch (err) {
      console.warn(`[lust-calls] ${label}: batch of ${chunk.length} failed entirely: ${err}`);
    }
  }
  return out;
}

// ─── Orchestration + KV ──────────────────────────────────────────────────────

const LUST_CALLS_KEY = "lust_calls_v1";

export async function readLustCalls(kv: ZugzugKV): Promise<LustCallsBlob | null> {
  const raw = await kv.get(LUST_CALLS_KEY);
  if (raw === null) return null;
  try {
    return JSON.parse(raw) as LustCallsBlob;
  } catch {
    return null;
  }
}

export interface LustSweepOpts {
  /** Sample size for the "top" cohort (rank 1-N). */
  runsPerDungeon?: number;
  /** Sample size for the bracket cohorts — bigger is better there: the
   *  neighborhoods are dense, and 100 runs make the ≥50% consensus and
   *  the median cast times much more robust than 5 ever could. */
  percentileRuns?: number;
  minSupport?: number;
  maxDepth?: number;
  maxCalls?: number;
  cohorts?: readonly LustCohort[];
}

/** Derive one dungeon's full entry (all requested cohorts), falling back to
 *  the previous sweep's data per-cohort (or wholesale on total failure). */
async function deriveDungeonEntry(
  token: string,
  dungeon: { id: number; name: string },
  opts: LustSweepOpts,
  previous: LustCallsBlob | null,
): Promise<DungeonLustCalls | null> {
  const runsPerDungeon = opts.runsPerDungeon ?? 5;
  const percentileRuns = opts.percentileRuns ?? 100;
  const cohorts = opts.cohorts ?? LUST_COHORTS;

  /** One cohort's body (no nested cohorts). */
  const deriveCohort = async (
    cohort: LustCohort,
    page1: RankingsPage,
  ): Promise<Omit<DungeonLustCalls, "cohorts"> | null> => {
    const sample = cohort === "top" ? runsPerDungeon : percentileRuns;
    const picked = await fetchCohortRuns(token, dungeon.id, sample, cohort, page1);
    const runs = await fetchRunCallsBatch(token, picked, `${dungeon.name}/${cohort}`);
    const calls = consensusCalls(runs, opts);
    console.log(
      `[lust-calls] ${dungeon.name}/${cohort}: ${runs.length}/${picked.length} runs → ${calls.length} calls`,
    );
    if (calls.length === 0) return null;
    return {
      dungeonName: dungeon.name,
      runsAnalyzed: runs.length,
      keystoneLevels: runs.map((r) => r.keystoneLevel),
      calls,
    };
  };

  /** Last sweep's body for this dungeon+cohort, so an outage keeps good data. */
  const previousCohort = (cohort: LustCohort): Omit<DungeonLustCalls, "cohorts"> | null => {
    const prev = previous?.dungeons.find((d) => d.dungeonName === dungeon.name);
    if (!prev) return null;
    if (cohort === "top") {
      return prev.calls.length > 0
        ? { dungeonName: prev.dungeonName, runsAnalyzed: prev.runsAnalyzed, keystoneLevels: prev.keystoneLevels, calls: prev.calls }
        : null;
    }
    const c = prev.cohorts?.[cohort];
    return c && c.calls.length > 0 ? c : null;
  };

  try {
    const page1 = await fetchRankingsPage(token, dungeon.id, 1);
    const bodies: Partial<Record<LustCohort, Omit<DungeonLustCalls, "cohorts">>> = {};
    for (const cohort of cohorts) {
      let body: Omit<DungeonLustCalls, "cohorts"> | null = null;
      try {
        body = await deriveCohort(cohort, page1);
      } catch (err) {
        console.warn(`[lust-calls] ${dungeon.name}/${cohort} failed: ${err}`);
      }
      body ??= previousCohort(cohort);
      if (body) bodies[cohort] = body;
    }

    const top = bodies.top ?? previousCohort("top");
    if (!top && !bodies.p1 && !bodies.p01) return null;
    const entry: DungeonLustCalls = top
      ? { ...top }
      : { dungeonName: dungeon.name, runsAnalyzed: 0, keystoneLevels: [], calls: [] };
    if (bodies.p1 || bodies.p01) {
      entry.cohorts = {};
      if (bodies.p1) entry.cohorts.p1 = bodies.p1;
      if (bodies.p01) entry.cohorts.p01 = bodies.p01;
    }
    return entry;
  } catch (err) {
    console.warn(`[lust-calls] ${dungeon.name} failed entirely: ${err}`);
    // Whole-dungeon failure (e.g. rankings page unavailable): carry the
    // previous entry forward untouched if there was one.
    return previous?.dungeons.find((d) => d.dungeonName === dungeon.name) ?? null;
  }
}

function blobHasAnyCalls(dungeons: DungeonLustCalls[]): boolean {
  return dungeons.some(
    (d) => d.calls.length > 0 || d.cohorts?.p1?.calls.length || d.cohorts?.p01?.calls.length,
  );
}

/**
 * Derive consensus lust calls for every dungeon × cohort and write them to
 * KV. With 100-run bracket cohorts this is ~1.7k report units paced at
 * ~500ms per request (several minutes wall) — callers must run it somewhere
 * that survives that (cron waitUntil or a Node script), NOT inline in a
 * held-open HTTP request. For request-sized work use refreshLustDungeon.
 */
export async function refreshLustCalls(
  creds: { clientId: string; clientSecret: string },
  kv: ZugzugKV,
  opts: LustSweepOpts = {},
): Promise<LustCallsBlob> {
  const { token } = await getV2Token(creds.clientId, creds.clientSecret);
  const previous = await readLustCalls(kv);

  const dungeons: DungeonLustCalls[] = [];
  for (const dungeon of DUNGEONS) {
    const entry = await deriveDungeonEntry(token, dungeon, opts, previous);
    if (entry) dungeons.push(entry);
  }

  const blob: LustCallsBlob = {
    generatedAt: new Date().toISOString(),
    dungeons,
  };
  // Only persist when the sweep produced something — a WCL outage shouldn't
  // wipe last week's good data.
  if (blobHasAnyCalls(dungeons)) {
    await kv.put(LUST_CALLS_KEY, JSON.stringify(blob));
  } else {
    console.warn("[lust-calls] sweep produced zero calls — keeping previous KV blob");
  }
  return blob;
}

/**
 * Refresh a single dungeon (0-based index into DUNGEONS) and merge it into
 * the KV blob, preserving every other dungeon's entry. Sized to complete
 * inside one ordinary worker invocation (~30-70s paced), so a driver can
 * walk the dungeons with 8 short requests instead of one fragile long one.
 */
export async function refreshLustDungeon(
  creds: { clientId: string; clientSecret: string },
  kv: ZugzugKV,
  dungeonIndex: number,
  opts: LustSweepOpts = {},
): Promise<{ dungeonName: string; calls: number; cohorts: string[] }> {
  const dungeon = DUNGEONS[dungeonIndex];
  if (!dungeon) throw new Error(`no dungeon at index ${dungeonIndex}`);
  const { token } = await getV2Token(creds.clientId, creds.clientSecret);
  const previous = await readLustCalls(kv);

  const entry = await deriveDungeonEntry(token, dungeon, opts, previous);

  // Rebuild the blob in DUNGEONS order: this dungeon's fresh entry plus
  // every other dungeon's previous entry.
  const dungeons: DungeonLustCalls[] = [];
  for (const d of DUNGEONS) {
    const e =
      d.name === dungeon.name
        ? entry
        : previous?.dungeons.find((p) => p.dungeonName === d.name) ?? null;
    if (e) dungeons.push(e);
  }
  if (blobHasAnyCalls(dungeons)) {
    await kv.put(
      LUST_CALLS_KEY,
      JSON.stringify({ generatedAt: new Date().toISOString(), dungeons } satisfies LustCallsBlob),
    );
  }
  return {
    dungeonName: dungeon.name,
    calls: entry?.calls.length ?? 0,
    cohorts: entry?.cohorts ? Object.keys(entry.cohorts) : [],
  };
}

/**
 * Diagnostic: raw + derived data for one dungeon (gated /probe-lust).
 * dungeonIndex is 0-based into DUNGEONS.
 */
export async function probeLustDungeon(
  creds: { clientId: string; clientSecret: string },
  dungeonIndex: number,
): Promise<unknown> {
  const dungeon = DUNGEONS[dungeonIndex] ?? DUNGEONS[0]!;
  const { token } = await getV2Token(creds.clientId, creds.clientSecret);
  const top = await fetchTopRuns(token, dungeon.id, 3);
  const runs: unknown[] = [];
  const parsed: RunCalls[] = [];
  for (const t of top) {
    const run = await fetchRunCalls(token, t.code, t.fightID, t.keystoneLevel);
    runs.push({ ...t, parsed: run });
    if (run) parsed.push(run);
  }
  return {
    dungeon: dungeon.name,
    topRuns: top,
    runs,
    consensus: consensusCalls(parsed),
  };
}
