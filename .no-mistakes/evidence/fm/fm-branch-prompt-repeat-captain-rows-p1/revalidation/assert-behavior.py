import json
from pathlib import Path
root=Path(__file__).parent
cases={
    "initial-unreported":("captain",False),
    "repeat-acknowledged":("routine",False),
    "repeat-again":("routine",False),
    "repeat-buried-history":("routine",False),
    "changed-decision":("captain",False),
    "changed-repeat":("routine",False),
    "resolved-idle":("routine",False),
    "away-initial":("captain",False),
    "away-repeat":("routine",False),
}
results=[]
for name,(verdict,silent) in cases.items():
    before=[json.loads(s) for s in (root/f"{name}-before.jsonl").read_text().splitlines()]
    after=[json.loads(s) for s in (root/f"{name}-after.jsonl").read_text().splitlines()]
    added=after[len(before):]
    engine=json.loads((root/f"{name}-result.json").read_text())
    failures=[]
    if after[:len(before)]!=before: failures.append("history mutated")
    if len(added)!=1: failures.append("expected one report")
    if any(r["verdict"]!=verdict or r.get("silent",False)!=silent for r in added): failures.append("incorrect verdict or visibility")
    if verdict=="captain" and any(r["task"]!=("budget-choice" if name.startswith("away-") else "migration-choice") for r in added): failures.append("captain report lost task identity")
    if engine.get("is_error") or engine.get("subtype")!="success" or engine.get("permission_denials"): failures.append("engine failure or permission denial")
    if (root/f"{name}-remaining-wakes.tsv").read_text().strip(): failures.append("wake not acknowledged")
    results.append({"name":name,"result":"fail" if failures else "pass","rows":added,"failures":failures})
(root/"behavior-assertions.json").write_text(json.dumps(results,indent=2)+"\n")
for r in results: print(r["name"],r["result"],json.dumps(r["rows"]))
raise SystemExit(any(r["failures"] for r in results))
