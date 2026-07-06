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

/** Current Mythic+ dungeon pool. */
export const DUNGEONS: Dungeon[] = [
  { id: 112526, name: "Algeth'ar Academy" },
  { id: 12811, name: "Magisters' Terrace" },
  { id: 12874, name: "Maisara Caverns" },
  { id: 12915, name: "Nexus-Point Xenas" },
  { id: 10658, name: "Pit of Saron" },
  { id: 361753, name: "Seat of Triumvirate" },
  { id: 61209, name: "Skyreach" },
  { id: 12805, name: "Windrunner Spire" },
];
