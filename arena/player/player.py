#!/usr/bin/env python3
"""The player kit: plugs one CLI agent into any arena board.

Loop: ask the board for the state; on our turn, write it into the notebook, wake the agent
fresh (it reads rules + state + its own notes), take ORDERS.json, send it, commit the notebook.

usage: player.py --board http://host:7000 --token-file tok --agent claude|codex|gemini|grok
                 --notebook ./notebook --logs ./logs [--model M] [--turn-timeout 900]
"""
import argparse, json, os, shlex, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# How each agent runs one turn headless, with full access to its own machine.
AGENTS = {
    "claude": lambda p, m: ["claude", "-p", p, "--dangerously-skip-permissions"] + (["--model", m] if m else []),
    "codex":  lambda p, m: ["codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"] + (["-m", m] if m else []) + [p],
    "gemini": lambda p, m: ["gemini", "--yolo", "--skip-trust"] + (["-m", m] if m else []) + ["-p", p],
    "grok":   lambda p, m: ["grok", "--always-approve"] + (["-m", m] if m else []) + ["-p", p],
}

def call(board, token, path, body=None):
    req = urllib.request.Request(board + path, method="POST" if body is not None else "GET",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read().decode()
        return json.loads(data) if r.headers.get_content_type() == "application/json" else data

def git(nb, *args):
    return subprocess.run(["git", "-C", nb, *args], capture_output=True, text=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--agent", required=True, choices=AGENTS)
    ap.add_argument("--model", default="")
    ap.add_argument("--notebook", default="notebook")
    ap.add_argument("--logs", default="logs")
    ap.add_argument("--turn-timeout", type=int, default=900)
    a = ap.parse_args()
    token = open(a.token_file).read().strip()
    nb, logs = os.path.abspath(a.notebook), os.path.abspath(a.logs)
    os.makedirs(nb, exist_ok=True); os.makedirs(logs, exist_ok=True)
    if not os.path.isdir(os.path.join(nb, ".git")):
        git(nb, "init", "-q")
        git(nb, "config", "user.name", f"{a.agent} player"); git(nb, "config", "user.email", "player@arena.local")
    open(os.path.join(nb, "RULES.md"), "w").write(call(a.board, token, "/rules"))
    notes = os.path.join(nb, "NOTES.md")
    if not os.path.exists(notes): open(notes, "w").write("# Notes\n\n(empty: first turn)\n")
    prompt = open(os.path.join(HERE, "PLAYER.md")).read()
    done_turn = None
    while True:
        try: st = call(a.board, token, "/state")
        except Exception as e:
            print("board unreachable:", e, flush=True); time.sleep(5); continue
        if st["status"] == "over":
            json.dump(st, open(os.path.join(nb, "STATE.json"), "w"), indent=1)
            git(nb, "add", "-A"); git(nb, "commit", "-qm", "game over")
            print("game over:", json.dumps(st["view"].get("gold", st["view"])), flush=True); return
        if st["status"] != "your_turn" or st["turn"] == done_turn:
            time.sleep(2); continue
        turn = st["turn"]
        json.dump(st, open(os.path.join(nb, "STATE.json"), "w"), indent=1)
        orders = os.path.join(nb, "ORDERS.json")
        if os.path.exists(orders): os.remove(orders)
        t0 = time.time()
        with open(os.path.join(logs, f"turn-{turn:05d}.log"), "w") as lf:
            try:
                subprocess.run(AGENTS[a.agent](prompt, a.model), cwd=nb, stdout=lf, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, timeout=a.turn_timeout)
            except subprocess.TimeoutExpired:
                lf.write("\n[player kit] agent ran out of time\n")
        try: body = json.load(open(orders))
        except Exception: body = {"turn": turn, "actions": []}
        body["turn"] = turn
        try: res = call(a.board, token, "/act", body)
        except Exception as e: res = {"ok": False, "error": str(e)}
        git(nb, "add", "-A"); git(nb, "commit", "-qm", f"turn {turn}")
        done_turn = turn
        print(f"turn {turn}: {json.dumps(body.get('actions'))} {res} ({time.time()-t0:.0f}s)", flush=True)

if __name__ == "__main__":
    main()
