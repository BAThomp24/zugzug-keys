/**
 * Shared type definitions used by both the web app and the Cloudflare Worker.
 */

/** Static configuration for a single playable class. */
export interface ClassConfig {
  /** WarcraftLogs numeric class id. */
  id: number;
  /** Display color for the class. */
  color: string;
  /** Map of spec id → spec display name. */
  specs: Record<number, string>;
  /**
   * Spec display name → WoW specialization ID (GetSpecializationInfo /
   * C_SpecializationInfo IDs, e.g. Affliction → 265). Locale-independent
   * key consumed by the companion addon. Specs absent from this map (e.g.
   * brand-new specs whose ID isn't confirmed yet) ship without a specId
   * and consumers fall back to name matching.
   */
  wowSpecIds?: Record<string, number>;
  /** DPS spec ids. */
  dpsSpecIds: number[];
  /** Healer spec ids. */
  healerSpecIds?: number[];
  /** Tank spec ids. */
  tankSpecIds?: number[];
  /**
   * Hero tree signature talents per spec name.
   * Used by V2 talent detection to classify which hero tree a player is using.
   * Maps spec name → { heroTreeName: [signatureTalentIds] }.
   */
  heroTrees?: Record<string, HeroTreeSignatures>;
}

/** Map of class name → class config. */
export type ClassConfigMap = Record<string, ClassConfig>;

/** A raid boss entry. */
export interface Boss {
  /** WCL encounter id. */
  id: number;
  /** Display name. */
  name: string;
  /** True for bosses of side instances (e.g. mini-raids) that ride along in
   *  BOSSES for build sampling but aren't part of the main raid's boss order. */
  sideInstance?: boolean;
}

/** A Mythic+ dungeon entry. */
export interface Dungeon {
  /** WCL encounter id. */
  id: number;
  /** Display name. */
  name: string;
}

// ─── Computed data returned by the worker ──────────────────────────────────

// ─── Gear hint types ─────────────────────────────────────────────────────────

export interface GearItemRef {
  itemId: number;
  name: string;
  icon?: string;
}

export interface TrinketPairing {
  trinkets: [GearItemRef, GearItemRef];
  usagePct: number;
}

export interface EmbellishmentHint {
  name: string;
  itemId?: number;
  usagePct: number;
}

export interface GearHints {
  sampleSize: number;
  topTrinketPairs: TrinketPairing[];
  topEmbellishments: EmbellishmentHint[];
  sampledFromEncounters: string[];
}

/**
 * A single canonical build for a class — identified by a talent fingerprint
 * shared by many top players. Used for both raid and M+ build columns.
 */
export interface Build {
  /** Stable id within the class (e.g. "build-0" or "other"). */
  id: string;
  /** Detected spec name. */
  spec: string;
  /** WoW specialization ID (e.g. 265 for Affliction) — locale-independent
   *  key for consumers like the addon. Absent on pre-feature cached blobs
   *  and on the "other" bucket. */
  specId?: number;
  /** Detected hero tree, or "" if unknown. */
  hero: string;
  /** Short header label used in the table (e.g. "Aldrachi"). */
  label: string;
  /** Display color (hex). */
  color: string;
  /** Talent fingerprint (sorted+joined talent ids), or "" for the Other bucket. */
  fingerprint: string;
  /** Live import string sniffed from logged loadouts, or "" if unknown. */
  importString: string;
  /** Global popularity in the primary bucket (0-100 percent share). */
  popularity: number;
  /**
   * Popularity trend vs the previous refresh snapshot.
   *   "new"   — didn't exist last refresh
   *   "up"    — share grew by >= POPULARITY_TREND_THRESHOLD
   *   "down"  — share shrunk by >= POPULARITY_TREND_THRESHOLD
   *   "flat"  — change below threshold
   */
  trend: "new" | "up" | "down" | "flat";
  raidGearHints?: GearHints;
  mpGearHints?: GearHints;
}

/**
 * A single talent that's picked at a meaningfully different rate on a specific
 * dungeon vs. the build's all-dungeon baseline. Used to surface "on Pit of
 * Saron, Affliction Warlocks pick Soul Rot 78% (vs 30% baseline)" insights.
 */
export interface TalentSwap {
  talentId: number;
  name: string;
  /** Pick rate among this build's parses on this dungeon (0–100). */
  dungeonPct: number;
  /** Pick rate among this build's parses across all dungeons (0–100). */
  baselinePct: number;
  /** "up" = picked more here; "down" = picked less here. */
  direction: "up" | "down";
}

/** Swap-detection result for one (build × dungeon-or-boss). */
export interface DungeonSwapEntry {
  /** Number of parses tagged to this build on this encounter. */
  sampleSize: number;
  /**
   * Talents picked at a meaningfully higher rate than the build's baseline.
   * Top ~3 by delta, each ≥ SWAP_DELTA_THRESHOLD. Empty if sample too small.
   */
  picks: TalentSwap[];
  /**
   * Talents picked LESS than the build's baseline — i.e. where the points
   * came from. If `picks` is non-empty but no individual drop clears the
   * threshold, the worker fills this with top drops anyway (so the
   * recommendation stays actionable: "to take X, drop Y").
   */
  drops: TalentSwap[];
  /**
   * @deprecated Pre-split shape. Blobs written before the picks/drops
   * refactor still have this; new computations write picks + drops above.
   */
  swaps?: TalentSwap[];
}

/** Per-dungeon result, bucketed by M+ key level. */
export interface DungeonResult {
  name: string;
  /** Array is parallel to `ClassData.mythicPlus.builds`, last entry is "Other". */
  buildCountsByBucket: Record<KeyLevelBucket, number[]>;
  totalByBucket: Record<KeyLevelBucket, number>;
  /** Top DPS/HPS string per bucket (e.g. "124k"). Empty when no data. */
  topDpsByBucket: Record<KeyLevelBucket, string>;
  /** Index of the dominant build per bucket. */
  bestBuildIndexByBucket: Record<KeyLevelBucket, number>;
  /**
   * Per-build talent-swap analysis. Array is parallel to `builds[]`; entries
   * for the "Other" bucket are empty. Optional because pre-feature cached
   * blobs won't have it until the next refresh writes a fresh one.
   */
  swapsByBuild?: DungeonSwapEntry[];
  /**
   * Encounter-specific import strings, indexed [bucket][buildIdx]. Each entry
   * is the import string of the most-common talent fingerprint among rankings
   * tagged to that (build × dungeon × bucket). Falls back to the base build's
   * importString on the web side when undefined (e.g. small sample size,
   * "Other" build, or no live import string was captured in any ranking).
   */
  importStringsByBucket?: Record<KeyLevelBucket, (string | undefined)[]>;
}

/** Per-boss result, bucketed by raid difficulty. */
export interface BossResult {
  name: string;
  /** Array is parallel to `ClassData.raid.builds`, last entry is "Other". */
  buildCountsByDifficulty: Record<Difficulty, number[]>;
  totalByDifficulty: Record<Difficulty, number>;
  /** Top DPS/HPS string per difficulty. */
  topDpsByDifficulty: Record<Difficulty, string>;
  /** Index of the dominant build per difficulty. */
  bestBuildIndexByDifficulty: Record<Difficulty, number>;
  /**
   * Per-difficulty, per-build talent-swap analysis. The inner array is
   * parallel to `builds[]`. Computed against a per-build baseline that
   * itself is per-difficulty (so heroic noise doesn't dilute mythic swaps).
   * Optional because pre-feature cached blobs won't have it until the next
   * refresh writes a fresh one.
   */
  swapsByBuild?: Record<Difficulty, DungeonSwapEntry[]>;
  /**
   * Encounter-specific import strings, indexed [difficulty][buildIdx]. Each
   * entry is the import string of the most-common fingerprint among rankings
   * tagged to that (build × boss × difficulty). Falls back to the base
   * build's importString on the web side when undefined.
   */
  importStringsByDifficulty?: Record<Difficulty, (string | undefined)[]>;
}

/**
 * M+ key-level filter buckets.
 * "all" — no filter
 * "15+" / "18+" / "20+" — include only rankings from keys at or above that level.
 */
export type KeyLevelBucket = "all" | "15+" | "18+" | "20+";

/** Ordered list of buckets for iteration and UI display. */
export const KEY_LEVEL_BUCKETS: readonly KeyLevelBucket[] = ["all", "15+", "18+", "20+"];

/** Minimum key level for each bucket; "all" has no minimum. */
export const KEY_LEVEL_MINIMUMS: Record<KeyLevelBucket, number> = {
  all: 0,
  "15+": 15,
  "18+": 18,
  "20+": 20,
};

/** A build card shown in the UI. */
export interface BuildCard {
  /** Short label (build name, e.g. "Aldrachi"). */
  label: string;
  /** Spec name. */
  spec: string;
  /** Hero talent tree. */
  hero: string;
  /** Short description (e.g. "All bosses 62%", "All dungeons 40%"). */
  description: string;
  /** Talent import string — may be empty if extraction failed. */
  importString: string;
}

/** All data for a single class after aggregation. */
export interface ClassData {
  color: string;
  raid: {
    cards: BuildCard[];
    builds: Build[];
    bosses: BossResult[];
    insights: string[];
  };
  mythicPlus: {
    /**
     * M+ build cards, per key-level bucket. Each bucket can have a different
     * dominant talent import string since top players often switch builds at
     * higher keys. For now every bucket shows the same card row.
     */
    cardsByBucket: Record<KeyLevelBucket, BuildCard[]>;
    builds: Build[];
    dungeons: DungeonResult[];
    insights: string[];
  };
}

/** Map of class name → aggregated class data. */
export type AllClassData = Record<string, ClassData>;

/** Player role — determines which spec ids and WCL metric to use. */
export type Role = "dps" | "healer" | "tank";

/** Raid difficulty — maps to WCL difficulty ids 4/5. Normal is skipped. */
export type Difficulty = "heroic" | "mythic";

/** Ordered list of raid difficulties for iteration and UI display. */
export const RAID_DIFFICULTIES: readonly Difficulty[] = ["heroic", "mythic"];

/**
 * A single weekly M+ score cutoff snapshot for the achievement leaderboard.
 * Populated by the cron worker from the Raider.io cutoffs API.
 */
export interface CutoffSnapshot {
  /** ISO date string for when this snapshot was taken. */
  date: string;
  /** Mythic+ score required to be in the top 1% of the region. */
  score1pct: number;
  /** Mythic+ score required to be in the top 0.1% of the region. */
  score01pct: number;
}

/**
 * Top-100 class makeup per role per difficulty. For each boss, the top 100
 * parses across every spec in the role are tallied by class; counts are
 * then averaged across bosses so a single high-throughput fight can't skew
 * the distribution. Values are average parse count per boss (sums to ~100).
 */
export type RaidTop100Makeup = Record<Role, Record<Difficulty, Record<string, number>>>;

/** Weekly snapshot of the top-100 raid class makeup, accumulated over time. */
export interface RaidMakeupSnapshot {
  /** ISO date string for when this snapshot was taken. */
  date: string;
  /** Per-role/difficulty class counts, same shape as RaidTop100Makeup. */
  makeup: RaidTop100Makeup;
}

/**
 * M+ class representation snapshot: for each role, maps class name → count
 * of unique players seen in top runs. Computed weekly from the Raider.io
 * top runs API.
 */
export interface MpRepresentationSnapshot {
  /** ISO date string for when this snapshot was taken. */
  date: string;
  /** Per-role class counts (unique players from top runs). */
  roles: Record<"dps" | "healer" | "tank", Record<string, number>>;
}

/**
 * Small boot-critical slice of ApiResponse served by GET /api/meta —
 * everything the home page's charts need, none of the multi-megabyte
 * per-class build data. Kept in its own KV key by writeLatest().
 */
export interface MetaResponse {
  lastUpdate: string;
  cutoffHistory?: CutoffSnapshot[];
  raidTop100Makeup?: RaidTop100Makeup;
  raidMakeupHistory?: RaidMakeupSnapshot[];
  mpRepresentation?: MpRepresentationSnapshot[];
  lastRefreshFailed?: boolean;
  lastRefreshFailedAt?: string;
}

/** Per-role class-data slice served by GET /api/role/:role. */
export interface RoleResponse {
  lastUpdate: string;
  classes: AllClassData;
}

/** Shape of the JSON blob stored in KV and returned by GET /api/data. */
export interface ApiResponse {
  /** ISO timestamp of the last successful pull. */
  lastUpdate: string;
  /** DPS class data keyed by class name. */
  classes: AllClassData;
  /** Healer class data keyed by class name. */
  healerClasses?: AllClassData;
  /** Tank class data keyed by class name. */
  tankClasses?: AllClassData;
  /**
   * Weekly M+ score cutoff history for the achievement leaderboard.
   * Accumulated by the cron worker; empty until the first cutoff fetch runs.
   */
  cutoffHistory?: CutoffSnapshot[];
  /** Top-100 class makeup per role/difficulty, computed by the assemble phase. */
  raidTop100Makeup?: RaidTop100Makeup;
  /** Weekly raid top-100 makeup snapshots, accumulated over time. */
  raidMakeupHistory?: RaidMakeupSnapshot[];
  /** Weekly M+ class representation snapshots from top Raider.io runs. */
  mpRepresentation?: MpRepresentationSnapshot[];
  /** Set when the most recent refresh job was aborted due to too many API failures. */
  lastRefreshFailed?: boolean;
  /** ISO timestamp of when the refresh failure occurred. */
  lastRefreshFailedAt?: string;
}

// ─── V2 talent detection types ───────────────────────────────────────────────

/** Maps hero tree name → array of signature talent IDs unique to that tree. */
export interface HeroTreeSignatures {
  [heroTreeName: string]: number[];
}

// ─── Visual talent tree types (for the slide-out tree panel) ────────────────

/** A single entry (rank) within a talent node. */
export interface VisualTalentEntry {
  id: number;
  name: string;
  icon: string;
  spellId: number;
  maxRanks: number;
  /** "active" = castable ability, "passive" = always-on, "tierrank" / "subtree" = structural. */
  entryType: string;
}

/** A positioned node in the visual talent tree. */
export interface VisualTalentNode {
  id: number;
  posX: number;
  posY: number;
  type: "single" | "choice" | "tiered" | "subtree";
  maxRanks: number;
  entries: VisualTalentEntry[];
  next: number[];
  prev: number[];
  /** Which section this node belongs to. */
  section: "class" | "spec" | "hero";
  /** For subtree/hero nodes: the hero tree name (e.g. "Aldrachi Reaver"). */
  subTreeName?: string;
}

/** A complete visual talent tree for one spec. */
export interface VisualTalentTree {
  className: string;
  specName: string;
  classId: number;
  specId: number;
  classNodes: VisualTalentNode[];
  specNodes: VisualTalentNode[];
  heroNodes: VisualTalentNode[];
}
