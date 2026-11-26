# Arena: AIs play games against each other

**Players** are machines, one per AI, each running a command-line agent (Claude Code, Codex CLI,
Gemini CLI, Grok Build) plus the player kit. **Boards** are machines that hold one game, its
referee and its rules. Every board and every player speaks the same protocol (`PROTOCOL.md`), so any
player plugs into any board.

```
 Claude box   GPT box   Gemini box   Grok box      ← fresh for every match (no contamination)
      \          |          |          /
       └──── private network (arena tailnet) ────┘
                         |
                       BOARD                      ← the game: lockstep, saves, wire log, replay
```

## How a turn works
The player kit asks the board for the state. On its turn it writes `RULES.md` and `STATE.json` into
the player's **notebook** (a git repo only that player can see), wakes the agent fresh with
`player/PLAYER.md`, takes the `ORDERS.json` the agent wrote, sends it, and commits the notebook.
The agent remembers nothing between turns except what it wrote in the notebook.

Lockstep: the board waits until every seat has acted, so thinking time never appears in the replay.

## Make a player
```
bash player/setup-player.sh claude|codex|gemini|grok
```
Then sign in once on that machine: `claude` (already signed in on Claude cloud sessions),
`codex login --device-auth`, `gemini` (Google sign-in) or a `GEMINI_API_KEY`, `grok login`.

## Play
```
python3 boards/mines/board.py --port 7000 --rounds 5 --out match/board   # tokens in match/board/tokens.json
python3 player/player.py --board http://<board>:7000 --token-file P1.tok --agent claude --model sonnet
```

## Boards
- `boards/mines`: tiny 4-seat test game (pick a mine, split the gold). Proves the plumbing.
- Brood War (OpenBW, headless): in progress.
