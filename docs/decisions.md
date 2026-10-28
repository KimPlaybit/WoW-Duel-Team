# Design decisions

Tracks the open decisions from spec §12. Newest first. "Provisional" means it can still change.

## 2026-10-28: Candidate duel locations (spec §12 #7; provisional, final spot not picked)

Feasibility testing and early development use these four spots. The final designated location is still open.

| # | Candidate | Faction | Setting | Notes |
|---|---|---|---|---|
| 1 | Outside the Orgrimmar gate | Horde | Open world, zone border (Orgrimmar / Durotar) | |
| 2 | Thunder Bluff, Hunter Rise | Horde | **Inside the capital city** | Verify that duels are allowed there on Forever |
| 3 | Outside the Ironforge gate | Alliance | Open world, zone border (Ironforge / Dun Morogh) | |
| 4 | Outside the Stormwind gate | Alliance | Open world, zone border (Stormwind / Elwynn Forest) | |

Consequences:
- Each spot belongs to one faction, so matches are implicitly same-faction. Cross-faction duels and whispers are
  normally impossible; this needs a decision if cross-faction matches are ever wanted.
- Location validation must accept a small *set* of areas (each spot: map ID + subzone + a radius around a
  reference point), not a single zone name. It must also tolerate players standing on either side of a zone border.
- Map IDs, subzone names and reference coordinates must be **recorded in game** with `/dp where` and logged in
  `docs/verification-log.md`, never filled in from memory.
- City spots have guards and heavy traffic (outside interference, spec §9.4). Note this during testing.
