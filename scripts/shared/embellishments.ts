/**
 * Embellishment bonus ID → display name map.
 *
 * Crafted gear in WoW carries a bonus ID that identifies the embellishment
 * effect applied to it. WCL returns these in the `bonusIDs` array of each
 * gear item in a ranking's combatantInfo.
 *
 * Update this map each major patch when new crafted items are added.
 * Midnight Season 1 entries — populate with actual bonus IDs once content ships.
 */
export const EMBELLISHMENT_BONUS_IDS: Record<number, string> = {
  // Example structure (The War Within Season 2 reference):
  // 10354: "Writhing Armor Banding",
  // 10355: "Pouch of Stolen Tricks",
  // 10356: "Shadowflame-Tempered Armor Patch",
  // 10394: "Duskthread Lining",
  // 10413: "Defender's Armor Kit",
  // 10416: "Finishing Rune",
};
