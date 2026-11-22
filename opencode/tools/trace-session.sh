#!/usr/bin/env bash
# Affiche les outils réellement appelés pendant une session OpenCode, sous-agents compris.
# Usage : trace-session.sh            dernière session
#         trace-session.sh -l         liste les 10 dernières sessions (numéro, date, titre)
#         trace-session.sh <numéro>   session n° <numéro> de la liste (1 = la plus récente)
# Lecture : « tool=task <sous-agent> » = délégation ; lignes « agent=<sous-agent> » = ce qu'il a fait ;
#           tool=edit ou tool=write = écriture de fichier ; [error] = commande refusée ou en échec.
# Code retour : 0 si la session est trouvée, 1 sinon.
set -euo pipefail
STOCKAGE="${OPENCODE_STORAGE:-${HOME}/.local/share/opencode/storage}"
[[ -d "$STOCKAGE/session" ]] || { echo "Aucun historique OpenCode dans $STOCKAGE" >&2; exit 1; }
python3 -I - "$STOCKAGE" "${1:-1}" <<'PY'
import json, glob, os, sys, datetime
st, arg = sys.argv[1], sys.argv[2]
def charge(f):
    try: return json.load(open(f))
    except Exception: return None
sessions = [s for s in map(charge, glob.glob(st + '/session/*/*.json')) if s]
racines = sorted((s for s in sessions if not s.get('parentID')), key=lambda s: s['time']['updated'], reverse=True)
if arg == '-l':
    for i, s in enumerate(racines[:10], 1):
        d = datetime.datetime.fromtimestamp(s['time']['updated'] / 1000).strftime('%Y-%m-%d %H:%M')
        print(f"{i:>2}  {d}  {s.get('title', '')}")
    sys.exit(0)
if not arg.isdigit() or not 1 <= int(arg) <= len(racines):
    print(f"Session {arg} introuvable (voir -l)", file=sys.stderr); sys.exit(1)
racine = racines[int(arg) - 1]
ids = {racine['id']} | {s['id'] for s in sessions if s.get('parentID') == racine['id']}
agents = {}
for sid in ids:
    for f in glob.glob(f"{st}/message/{sid}/*.json"):
        m = charge(f)
        if m: agents[m['id']] = m.get('agent') or m.get('mode') or '?'
lignes = []
for mid in agents:
    for f in glob.glob(f"{st}/part/{mid}/*.json"):
        p = charge(f)
        if not p or p.get('type') != 'tool': continue
        e = p.get('state') or {}
        i = e.get('input') or {}
        detail = i.get('subagent_type') or i.get('command') or i.get('filePath') or i.get('pattern') or ''
        debut = (e.get('time') or {}).get('start') or 0
        lignes.append((debut, f"agent={agents[mid]:<15} tool={p.get('tool'):<5} {detail} [{e.get('status')}]"))
print(f"# Session : {racine.get('title', '')} ({racine['directory']})")
for _, l in sorted(lignes): print(l)
PY
