"""Query the WoW: Forever API dump (.ref/WoW-Addons/docs/api.json).

Usage:
  python -I .claude/skills/wow-forever-api/scripts/api_lookup.py <regex> [--kind functions|events|tables|globals] [--full]

Matches function/event/table names (and event literal names like DUEL_FINISHED)
case-insensitively. Globals are undocumented legacy functions: the dump only
proves they EXIST, not their signature.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
API = os.path.join(ROOT, ".ref", "WoW-Addons", "docs", "api.json")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    if not os.path.exists(API):
        print(f"api.json not found at {API}. Run the setup step in wow-forever-api/SKILL.md.")
        return 1
    pat = re.compile(args[0], re.I)
    kind = None
    for i, a in enumerate(sys.argv):
        if a == "--kind" and i + 1 < len(sys.argv):
            kind = sys.argv[i + 1]
            args = [x for x in args if x != kind]
    full = "--full" in flags

    with open(API, encoding="utf-8") as f:
        d = json.load(f)
    m = d["meta"]
    print(f"# dump: {m['product']} v{m['version']} build {m['build']} interface {m['interface']} exported {m['exportedAt']}")

    hits = 0
    documented = set()
    for s in d["systems"]:
        ns = s.get("namespace")
        for item in s.get("functions") or []:
            documented.add((ns + "." if ns else "") + item.get("name", ""))
    for s in d["systems"]:
        ns = s.get("namespace")
        for k in ("functions", "events", "tables"):
            if kind and kind != k:
                continue
            for item in s.get(k) or []:
                name = item.get("name", "")
                lit = item.get("literalName") or ""
                if not (pat.search(name) or pat.search(lit)):
                    continue
                hits += 1
                qual = lit or ((ns + "." if ns else "") + name)
                if k == "functions":
                    a = ", ".join(f"{x['name']}{'?' if x.get('nilable') else ''}: {x['type']}" for x in item.get("arguments", []))
                    r = ", ".join(f"{x['name']}{'?' if x.get('nilable') else ''}: {x['type']}" for x in item.get("returns", []))
                    print(f"[fn]    {qual}({a}) -> {r or '()'}")
                elif k == "events":
                    p = ", ".join(f"{x['name']}: {x['type']}" for x in item.get("payload", []))
                    print(f"[event] {qual}  payload({p})  system={s.get('name')}")
                else:
                    print(f"[type]  {name}  ({item.get('type')})")
                if item.get("documentation"):
                    print(f"        doc: {item['documentation']}")
                if full:
                    print("        " + json.dumps(item))

    if not kind or kind == "globals":
        for g, v in d["globals"].items():
            if isinstance(v, list):
                for member in v:
                    if pat.search(member) or pat.search(g + "." + member):
                        hits += 1
                        print(f"[global] {g}.{member}  (exists; check documented form above)")
            elif pat.search(g) and g not in documented:
                hits += 1
                print(f"[global] {g}  ({v}; undocumented: signature NOT verified)")
    print(f"# {hits} match(es)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
