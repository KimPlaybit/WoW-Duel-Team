# Technical Instructions for the WoW: Forever Team Duel Addon

You are implementing a World of Warcraft: Forever addon using Lua.

Before coding, read the product specification and investigate the actual WoW: Forever API. Do not assume Retail, Classic Era, or older addon tutorials accurately describe the target client.

## Required references

- WoW: Forever API reference: https://atraeau.github.io/WoW-Addons/
- Development environment and examples: https://github.com/Atraeau/WoW-Addons
- Relevant client-specific source or API dumps, where available.

## Rules

1. Verify API names, event payloads, function signatures, return types, and restrictions before using them.
2. Distinguish verified behavior from assumptions. Mark anything requiring an in-game test.
3. Never invent an API function or assume that a Retail example works unchanged.
4. Use modular Lua code with separate responsibilities for database, communication, match state, ratings, UI, and positioning.
5. Use SavedVariables for version-one persistence. Include database versioning and migration support.
6. Validate addon messages and protect against malformed, duplicated, stale, or inconsistent messages.
7. Treat all locally stored ratings and client-reported match results as untrusted.
8. Respect protected-action and player-interaction restrictions. Never assume a duel can be initiated or accepted automatically.
9. Verify access to opposing-player coordinates before implementing distance-based stalling detection.
10. Include a manual fallback for any action that cannot be automated.
11. Test each feature independently in WoW: Forever before integrating it into the complete match flow.

## First deliverable

Do not implement the full addon yet.

Produce a technical feasibility report covering:

- Duel lifecycle events and winner detection.
- Duel request and acceptance restrictions.
- Addon messaging between ungrouped opponents.
- SavedVariables persistence.
- Position and distance tracking for both fighters.
- Dynamic countdown feasibility.
- Stalling detection and forfeits.
- UI and timer implementation.
- Designated-location validation.

For every finding, state whether it is verified, partially supported, unverified, or unsupported. Provide references or concrete in-game test procedures.

Then recommend the smallest prototype that validates the highest-risk assumptions before the main implementation begins.