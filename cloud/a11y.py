#!/usr/bin/python3.12
"""Drive the desktop through the accessibility tree.
  a11y.py apps                         list applications
  a11y.py tree APP [WIN_SUBSTR] [N]    headings/links/buttons/text in the window (first N, default 120)
  a11y.py do APP WIN ROLE NAME [ACT]   run an action (default first: click/press/jump) on the first match
  a11y.py focus APP WIN ROLE NAME      grab focus on the first match
"""
import sys, pyatspi

WANT = {"heading", "link", "push button", "toggle button", "entry", "check box", "radio button", "combo box",
        "menu item", "page tab", "list item", "label", "static", "paragraph", "section", "text"}

def apps():
    d = pyatspi.Registry.getDesktop(0)
    return [d.getChildAtIndex(i) for i in range(d.childCount) if d.getChildAtIndex(i)]

def app(name):
    for a in apps():
        if a and name.lower() in (a.name or "").lower():
            return a
    sys.exit(f"no app {name}")

def window(a, sub):
    for i in range(a.childCount):
        w = a.getChildAtIndex(i)
        if w and (not sub or sub.lower() in (w.name or "").lower()):
            return w
    sys.exit(f"no window {sub}")

def walk(n, depth=0, out=None, limit=4000):
    out = [] if out is None else out
    if n is None or len(out) > limit:
        return out
    try:
        role = n.getRoleName(); name = (n.name or "").strip()
        st = n.getState()
        if st.contains(pyatspi.STATE_SHOWING) or depth < 6:
            out.append((depth, role, name, n))
        for i in range(min(n.childCount, 400)):
            walk(n.getChildAtIndex(i), depth + 1, out, limit)
    except Exception:
        pass
    return out

def find(w, role, name):
    # An exact name first: a partial match can hit a bookmark or a tab whose title merely contains the name.
    hits = [(nm, n) for d, r, nm, n in walk(w) if r == role and name.lower() in nm.lower()]
    key = lambda t: "".join(ch for ch in t.lower() if ch.isalnum())   # icon glyphs and spaces don't count
    for nm, n in hits:
        if key(nm) == key(name):
            return n
    if hits:
        return hits[0][1]
    sys.exit(f"no {role} '{name}'")

cmd = sys.argv[1] if len(sys.argv) > 1 else "apps"
if cmd == "apps":
    for a in apps():
        print(a.name, "-", a.childCount, "windows:", [a.getChildAtIndex(i).name for i in range(a.childCount)])
elif cmd == "tree":
    a = app(sys.argv[2]); w = window(a, sys.argv[3] if len(sys.argv) > 3 else "")
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 120
    shown = 0
    for d, r, nm, node in walk(w):
        if r in WANT and nm:
            print(f"{'  ' * min(d, 12)}[{r}] {nm[:110]}"); shown += 1
            if shown >= n: break
elif cmd in ("do", "focus"):
    a = app(sys.argv[2]); w = window(a, sys.argv[3]); node = find(w, sys.argv[4], sys.argv[5])
    if cmd == "focus":
        print("focus:", node.queryComponent().grabFocus())
    else:
        act = node.queryAction(); want = sys.argv[6] if len(sys.argv) > 6 else None
        names = [act.getName(i) for i in range(act.nActions)]
        i = names.index(want) if want in names else 0
        print("actions:", names, "-> doing", names[i] if names else None, act.doAction(i) if names else "")
