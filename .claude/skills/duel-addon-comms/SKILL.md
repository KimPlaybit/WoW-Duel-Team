---
name: duel-addon-comms
description: Design and implementation rules for the Team Duel addon's client-to-client protocol (C_ChatInfo addon messages). Use when designing message types, writing Comm.lua, handling CHAT_MSG_ADDON, synchronizing match state between clients, reconciling conflicting duel results, or dealing with throttling, lockdown, disconnects or untrusted senders.
---

# Team Duel addon communication protocol

Spec §2.1C, §11.2, §11.4; info rules 6–7. Transport facts are in
`.claude/skills/wow-forever-api/references/restrictions.md`.

## Transport constraints (re-verify on Forever)
- Prefix ≤ 16 chars, for example `"TDuel1"`. Register it at load and check the result.
- ≤ 255 bytes per message. 10 messages per prefix, regenerating at 1/sec (Retail defaults). `Success` = queued, **not delivered**.
- Channel choice:
  - Grouped (preferred, since `UnitPosition` also needs a group): `PARTY` for 1v1 and 2v2, `RAID` for 3v3 (6 players).
  - Ungrouped: `WHISPER` to each participant, one message per recipient, so it costs more against the budget.
- Possible failures: `AddOnMessageLockdown`, `AddonMessageThrottle`, `NotInGroup`, `TargetOffline`, trial accounts (cannot send).
  **Unverified whether a duel triggers lockdown**, so the protocol must not depend on messages *during* a duel.

## Envelope
`v|type|matchId|seq|ts|payload`, where:
- `v` is the protocol version. Ignore messages with an unknown major version and warn once.
- `matchId` is the creator's `Name-Realm` plus `GetServerTime()` plus a random suffix.
- `seq` is a per-sender monotonic integer.
- `ts` is the `GetServerTime()` at sending.
- `payload` is either short `k=v;` pairs or CBOR+Base64 (`C_EncodingUtil`). Both must stay ≤ 255 bytes total.
  If a payload can't fit, split it with `part/total` and reassemble with a timeout.

## Message types (initial)
`HELLO` (version, rating snapshot) · `CHALLENGE` (format, roster, ratings, location) · `ACCEPT` / `DECLINE` ·
`ORDER` (team fighter order; locked once both teams have sent it) · `READY` · `POS` (y, x, instanceID, t) ·
`DUEL_RESULT` (duelIndex, winner, loser, how, local evidence) · `STATE` (full snapshot hash plus key fields, for resync) ·
`FORFEIT` (team, reason, evidence) · `ACK` (type, seq) · `ABORT` (reason).

## Validation pipeline (every incoming message)
1. Check the prefix, then parse the envelope. Drop malformed messages, with a debug log line.
2. Normalize the sender with `Ambiguate(sender, "none")` and the full `Name-Realm` form. **The sender must be a participant** in `matchId`
   (CHALLENGE and ACCEPT are the exceptions, since they create the match).
3. Drop a duplicate `(sender, seq)`. Drop the message if `seq` is ≤ the last one applied from that sender (it is stale).
4. Drop it if `matchId` isn't the active match, unless the type is a match-creation message.
5. Type-check and range-check every field: format ∈ {1,2,3}, the roster size matches the format, names are participants,
   ratings are within sane bounds.
6. Check it against the state machine. A message that isn't legal in the current state is logged and ignored, and it doesn't throw.
7. Never `loadstring` or execute received data.

## Reliability
- Critical messages (CHALLENGE, ACCEPT, ORDER, DUEL_RESULT, FORFEIT) are ACKed. Retry with backoff (1s, 2s, 4s), then
  mark the peer unreachable and pause the match. **Do not silently decide the match.**
- Use one outgoing queue per prefix with a token bucket that mirrors the throttle. Positions get low priority, and stale POS entries are coalesced.
- On reconnect, or after a gap in `seq`, request a `STATE` snapshot. A `STATE` from the match creator is used as the tie-break only for
  *ordering* data, never for results.

## Result agreement (results are untrusted)
- Each duelist's client reports its own observation of the duel (`DUEL_RESULT` with evidence: the system message text,
  `DUEL_FINISHED` timing, its own death or health state).
- The result is **confirmed** only when both duelists' reports agree, or when one report plus a corroborating teammate observation agree.
- If they conflict, are missing, or are ambiguous, the duel is marked **disputed**: no rating change, and both teams are prompted to
  re-run the duel or abort. This satisfies "failures must not silently produce incorrect winners" (§11.4).
- Ratings are applied locally by each client from the confirmed result. Each client persists its own view. Local data is never treated as authoritative.

## Testing
- Pure encode/decode/validate functions get unit tests with malformed, oversized, duplicate, stale, wrong-match and non-participant cases.
- In game: `/td commtest <name>` sends N messages over each channel type and reports the result codes and the round-trip times.
