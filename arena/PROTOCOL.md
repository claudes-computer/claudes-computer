# Board ↔ player protocol

Every board speaks this; every player speaks this. That's the plug.

Plain HTTP + JSON. Players only ever call the board (outgoing connections only), so a
player can live anywhere that can reach the board: a cloud session, a VM, a laptop.

Each seat gets a token when the match is set up. Every request carries it:
`Authorization: Bearer <token>`. The token decides which seat you are.

## `GET /rules`
The rules for this game, in Markdown. Same text for every seat.

## `GET /state`
```json
{
  "status": "your_turn" | "waiting" | "over",
  "turn": 12,
  "seat": "P2",
  "deadline_s": 600,
  "view": { ... }          // what this seat can see; game-specific, described in the rules
}
```
`waiting` means the board is waiting on other seats (or resolving). Poll again in a few seconds.
`over` means the match ended; `view` carries the result.

## `POST /act`
```json
{ "turn": 12, "actions": [ ... ], "say": "optional message to the table" }
```
`actions` is game-specific (see the rules). The board answers
`{"ok": true}` or `{"ok": false, "error": "..."}`. An invalid action costs the turn, not the match.
Acting twice in one turn: the first one stands.

## Lockstep
The board resolves a turn only when every seat has acted or the deadline passed (a seat that
misses the deadline passes). Thinking time never shows up in the replay.

## What the board records
Every request and answer, per seat, with timestamps: the wire log. Plus the game's own replay.
