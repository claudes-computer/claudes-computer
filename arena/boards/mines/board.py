#!/usr/bin/env python3
"""Mines: a tiny 4-seat test board. Proves players can join, read rules, keep notes and act.

Each round, every seat secretly picks one of four mines. A mine's gold is split evenly
among everyone who picked it. Values change every round; seats see the history.
Most gold after the last round wins.

usage: board.py --port 7000 --rounds 8 --seats P1,P2,P3,P4 --out /path/to/match
Tokens are written to <out>/tokens.json (hand each seat its own).
"""
import argparse, json, os, random, secrets, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

RULES = """# Mines

Four seats play. Each round there are four mines, A B C D, each holding some gold
(shown in `view.mines`). Every seat secretly picks one mine. When all have picked, each mine's
gold is split evenly among the seats that picked it (rounded down). Nobody else's pick is
known until the round resolves; then `view.history` shows who picked what.

You may also say one short message to the table each round (`say`). Everyone sees it
next round in `view.history`. Talk is cheap: nothing forces anyone to keep their word.

Most gold after the last round wins.

## Your action
`{"turn": <turn>, "actions": [{"pick": "A"}], "say": "optional"}`
"""

class Game:
    def __init__(s, seats, rounds, seed):
        s.rng = random.Random(seed)
        s.seats, s.rounds = seats, rounds
        s.turn, s.over = 1, False
        s.gold = {p: 0 for p in seats}
        s.history = []
        s.pending = {}
        s.deal()

    def deal(s):
        s.mines = {m: s.rng.choice([4, 6, 8, 10, 12, 20]) for m in "ABCD"}

    def view(s, seat):
        return {"round": s.turn, "of": s.rounds, "mines": s.mines, "gold": s.gold,
                "you": seat, "history": s.history[-6:]}

    def act(s, seat, body):
        if s.over: return "match is over"
        if body.get("turn") != s.turn: return f"it is turn {s.turn}"
        if seat in s.pending: return None  # first one stands
        try: pick = body["actions"][0]["pick"]
        except Exception: pick = None
        if pick not in s.mines: pick = None  # invalid: passes
        s.pending[seat] = {"pick": pick, "say": str(body.get("say", ""))[:280]}
        return None

    def resolve(s):
        picks = {p: s.pending.get(p, {"pick": None, "say": ""}) for p in s.seats}
        for m, g in s.mines.items():
            who = [p for p in s.seats if picks[p]["pick"] == m]
            for p in who: s.gold[p] += g // len(who)
        s.history.append({"round": s.turn, "mines": s.mines, "picks": {p: v["pick"] for p, v in picks.items()},
                          "said": {p: v["say"] for p, v in picks.items() if v["say"]}})
        s.pending = {}
        if s.turn >= s.rounds: s.over = True
        else: s.turn += 1; s.deal()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7000)
    ap.add_argument("--rounds", type=int, default=8)
    ap.add_argument("--seats", default="P1,P2,P3,P4")
    ap.add_argument("--deadline", type=int, default=900)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    seats = a.seats.split(",")
    tok_file = os.path.join(a.out, "tokens.json")
    tokens = json.load(open(tok_file)) if os.path.exists(tok_file) else {p: secrets.token_hex(12) for p in seats}
    json.dump(tokens, open(tok_file, "w"), indent=1); os.chmod(tok_file, 0o600)
    by_token = {t: p for p, t in tokens.items()}
    g = Game(seats, a.rounds, a.seed)
    lock = threading.Lock()
    wire = open(os.path.join(a.out, "wire.jsonl"), "a")
    turn_started = [time.time()]

    def log(**kw):
        kw["t"] = round(time.time(), 3); wire.write(json.dumps(kw) + "\n"); wire.flush()

    def tick():
        while True:
            time.sleep(1)
            with lock:
                if g.over: continue
                if len(g.pending) == len(seats) or time.time() - turn_started[0] > a.deadline:
                    g.resolve(); turn_started[0] = time.time()
                    log(event="resolved", turn=g.turn, gold=g.gold, over=g.over)
                    json.dump({"history": g.history, "gold": g.gold, "over": g.over},
                              open(os.path.join(a.out, "replay.json"), "w"), indent=1)
    threading.Thread(target=tick, daemon=True).start()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *x): pass
        def seat(self):
            t = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
            return by_token.get(t)
        def send(self, code, obj, ctype="application/json"):
            b = obj.encode() if isinstance(obj, str) else json.dumps(obj).encode()
            self.send_response(code); self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def do_GET(self):
            seat = self.seat()
            if not seat: return self.send(401, {"error": "bad token"})
            with lock:
                if self.path == "/rules": return self.send(200, RULES, "text/markdown")
                if self.path == "/state":
                    st = "over" if g.over else ("waiting" if seat in g.pending else "your_turn")
                    left = max(0, int(a.deadline - (time.time() - turn_started[0])))
                    return self.send(200, {"status": st, "turn": g.turn, "seat": seat,
                                           "deadline_s": left, "view": g.view(seat)})
            self.send(404, {"error": "no such path"})
        def do_POST(self):
            seat = self.seat()
            if not seat: return self.send(401, {"error": "bad token"})
            n = int(self.headers.get("Content-Length", 0) or 0)
            try: body = json.loads(self.rfile.read(n) or b"{}")
            except Exception: return self.send(400, {"ok": False, "error": "not JSON"})
            if self.path != "/act": return self.send(404, {"error": "no such path"})
            with lock:
                err = g.act(seat, body); log(event="act", seat=seat, body=body, error=err)
            self.send(200, {"ok": err is None, **({"error": err} if err else {})})

    print(f"mines board on :{a.port}, seats {seats}, tokens in {tok_file}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()

if __name__ == "__main__":
    main()
