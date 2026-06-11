----------------------------------------------------------------------
-- ZugZug Keys — Lust Data
-- Curated boss-level fallback recommendations for when MDT isn't loaded
-- or the loaded route has no recognisable lust marker. Indexed by the
-- challenge map ID returned by C_ChallengeMode.GetActiveChallengeMapID.
--
-- Each entry: { name, encounterIDs, note }
--   name: human label for chat output
--   encounterIDs: list of bossIDs (from ENCOUNTER_START) where lust is
--     recommended at the START of the encounter
--   note: free-form explanation shown in chat
--
-- Numbers below are placeholders — populate per the current Midnight S1
-- meta after sanity-checking against Tactyks / Keystone.guru top routes.
-- Comment out / nil out the entries you haven't validated; the runtime
-- treats missing entries as "no recommendation" and stays silent.
----------------------------------------------------------------------

ZugZugKeysLustData = {
  -- Example shape (replace mapID + encounterIDs with real values):
  -- [<challengeMapID>] = {
  --   name = "Dungeon Name",
  --   encounterIDs = { <bossID> },
  --   note = "Lust on boss 2 — consensus from top S1 routes",
  -- },

  -- TODO(Midnight S1 — populate after validating against current routes):
  -- [ <Seat of the Triumvirate mapID> ] = { name = "Seat of the Triumvirate", encounterIDs = { ??? }, note = "..." },
  -- [ <Nexus-Point Xenas mapID>      ] = { name = "Nexus-Point Xenas",      encounterIDs = { ??? }, note = "..." },
  -- [ <Pit of Saron mapID>           ] = { name = "Pit of Saron",           encounterIDs = { ??? }, note = "..." },
  -- [ <Magisters' Terrace mapID>     ] = { name = "Magisters' Terrace",     encounterIDs = { ??? }, note = "..." },
  -- [ <Algeth'ar Academy mapID>      ] = { name = "Algeth'ar Academy",      encounterIDs = { ??? }, note = "..." },
  -- [ <Cinderbrew Meadery mapID>     ] = { name = "Cinderbrew Meadery",     encounterIDs = { ??? }, note = "..." },
  -- [ <Silvermoon City mapID>        ] = { name = "Silvermoon City",        encounterIDs = { ??? }, note = "..." },
}
