import type { Boss, Dungeon } from "./types.js";

/** Midnight raid bosses ordered as they appear in the instance.
 *  Rotmire is the lone boss of the Sporefall mini-raid added in patch 12.0.7
 *  (June 2026); kept at the end of the array because Sporefall is a separate
 *  weekly clear that sits alongside the main raid, not a new wing of it. */
export const BOSSES: Boss[] = [
  { id: 3176, name: "Imperator Averzian" },
  { id: 3177, name: "Vorasius" },
  { id: 3179, name: "Fallen-King Salhadaar" },
  { id: 3178, name: "Vaelgor & Ezzorak" },
  { id: 3180, name: "Lightblinded Vanguard" },
  { id: 3181, name: "Crown of the Cosmos" },
  { id: 3306, name: "Chimaerus" },
  { id: 3182, name: "Belo'ren" },
  { id: 3183, name: "Midnight Falls" },
  { id: 3159, name: "Rotmire", sideInstance: true },
];

/** Current Mythic+ dungeon pool — Midnight Season 2 (from 2026-08-18).
 *
 * These are WarcraftLogs ENCOUNTER ids, and they change every season. To
 * roll over, take the encounters of the one unfrozen "Mythic+ Season N"
 * zone under the current expansion:
 *
 *   { worldData { expansions { name zones { id name frozen
 *       encounters { id name } } } } }
 *
 * Getting this wrong fails quietly rather than loudly: the previous
 * season's zone still answers, with frozen historical logs, so the
 * weekly job keeps "succeeding" and shipping calls for dungeons nobody
 * is running. Season 1's pool sat here for the first ten days of Season
 * 2 and every lust reminder in a key came back empty.
 *
 * Names are WCL's; LustReminder's normalizeDungeon() folds punctuation
 * and "the" away, so a differing apostrophe still matches the in-game name.
 */
export const DUNGEONS: Dungeon[] = [
  { id: 12993, name: "Altar of Fangs" },
  { id: 12825, name: "Den of Nalorakk" },
  { id: 61762, name: "King's Rest" },
  { id: 12813, name: "Murder Row" },
  { id: 112521, name: "Ruby Life Pools" },
  { id: 61877, name: "Temple of Sethraliss" },
  { id: 12859, name: "The Blinding Vale" },
  { id: 12923, name: "Voidscar Arena" },
];
