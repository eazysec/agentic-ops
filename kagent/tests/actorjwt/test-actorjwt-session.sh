#!/usr/bin/env bash
# Run a diagnostic session and verify the actual tool response and proxy trace.
set -euo pipefail
: "${KUBECONFIG:?Set KUBECONFIG to the kagent cluster kubeconfig}"
agent=${1:?Usage: test-actorjwt-session.sh AGENT}
namespace=${KAGENT_NAMESPACE:-kagent}
workload_namespace=${WORKLOAD_NAMESPACE:-banc}
kubectl_bin=${KUBECTL:-kubectl137}
port=${KAGENT_LOCAL_PORT:-18083}
proxy_deployment=${MCP_PROXY_DEPLOYMENT:-kagent-mcp-auth}
expect=${MCP_EXPECT:-allow}
case "$expect" in allow|deny) ;; *) printf 'MCP_EXPECT must be allow or deny\n' >&2; exit 2 ;; esac
work=$(mktemp -d)
"$kubectl_bin" -n "$namespace" port-forward svc/kagent-controller "$port:8083" >"$work/forward" 2>&1 &
forward=$!
trap 'kill "$forward" 2>/dev/null || true; rm -r -- "$work"' EXIT

for ((attempt=0; attempt<40; attempt++)); do
    if grep -q 'Forwarding from' "$work/forward"; then
        break
    fi
    sleep 0.25
done
grep -q 'Forwarding from' "$work/forward" || { cat "$work/forward" >&2; exit 1; }

call_kagent() {
    local url="http://127.0.0.1:$port"
    kagent --namespace "$namespace" --api-url "$url" --gateway-url "$url" --timeout 120s "$@"
}

"$kubectl_bin" -n "$namespace" wait --for=condition=Ready "agent/$agent" --timeout=90s
revisions=$("$kubectl_bin" -n "$namespace" get agent "$agent" \
    -o jsonpath='{.status.desiredRevision}{" "}{.status.latestSuccessfulRevision}')
read -r desired successful <<< "$revisions"
if [[ -z "$desired" || "$desired" != "$successful" ]]; then
    printf 'Agent %s has no ready desired revision: %s\n' "$agent" "$revisions" >&2
    exit 1
fi

session=$(call_kagent agent session create --agent "$agent" -o json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["id"])')
invoke_status=0
call_kagent agent invoke --session "$session" -o json \
    --task "Appelle k8s_get_events avec uniquement namespace=${workload_namespace}. Résume les événements lus." >"$work/result" || invoke_status=$?
if [[ "$expect" == deny ]]; then
    "$kubectl_bin" -n "$namespace" logs "deployment/$proxy_deployment" -c gateway --since=5m >"$work/proxy"
    grep -F "jwt.sub=actor/$namespace/session-$session " "$work/proxy" >"$work/session-proxy"
    grep -E 'http.path=/mcp .*http.status=403' "$work/session-proxy" >/dev/null
    if grep -E 'http.path=/mcp .*http.status=2[0-9][0-9]' "$work/session-proxy"; then
        printf 'Unexpected MCP success for denied agent %s\n' "$agent" >&2
        exit 1
    fi
    printf 'OK authenticated MCP request denied for %s (session %s)\n' "$agent" "$session"
    exit 0
fi
(( invoke_status == 0 )) || exit "$invoke_status"
python3 - "$work/result" <<'PY'
import json
import sys
with open(sys.argv[1]) as result:
    task = json.load(result)["task"]
assert task["status"]["state"] == "TASK_STATE_COMPLETED", task["status"]["state"]
for artifact in task.get("artifacts", []):
    for part in artifact.get("parts", []):
        data = part.get("data", {})
        if data.get("name") != "k8s_get_events" or "response" not in data:
            continue
        output = data["response"].get("output", {}).get("output")
        if not isinstance(output, str):
            continue
        try:
            events = json.loads(output)
        except json.JSONDecodeError:
            continue
        if isinstance(events, dict) and isinstance(events.get("items"), list):
            print(f"OK k8s_get_events: {len(events['items'])} events")
            sys.exit(0)
sys.exit("No successful Kubernetes event-list tool response")
PY
"$kubectl_bin" -n "$namespace" logs "deployment/$proxy_deployment" -c gateway --since=5m >"$work/proxy"
if ! grep -F "jwt.sub=actor/$namespace/session-$session " "$work/proxy" |
    grep -E 'http.method=POST .*http.path=/mcp .*http.status=200' >"$work/session-proxy"; then
    printf 'No authenticated MCP trace for %s (session %s)\n' "$agent" "$session" >&2
    exit 1
fi
printf 'OK authenticated MCP trace for %s (session %s)\n' "$agent" "$session"
