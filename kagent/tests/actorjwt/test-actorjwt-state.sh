#!/usr/bin/env bash
# Read-only checks for the final ActorJWT configuration.
set -euo pipefail

: "${KUBECONFIG:?Set KUBECONFIG to the kubeconfig of the kagent cluster}"
kubectl_bin=${KUBECTL:-kubectl137}
namespace=${KAGENT_NAMESPACE:-kagent}
workload_namespace=${WORKLOAD_NAMESPACE:-banc}
server=${MCP_SERVER:-kagent-tools-authenticated}
audience=${MCP_AUDIENCE:-kagent-tools-mcp kagent-agent-info}
proxy_url=${MCP_PROXY_URL:-http://kagent-mcp-auth.kagent.svc.cluster.local:8080/mcp}
if (( $# == 0 )); then
    set -- diag-lecture diag-lecture-gpt41
fi

kube() {
    "$kubectl_bin" --request-timeout=10s "$@"
}

failures=0
expect() {
    local name=$1 expected=$2 actual=$3
    if [[ "$actual" == "$expected" ]]; then
        printf 'OK %s\n' "$name"
    else
        printf 'FAIL %s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2
        failures=$((failures + 1))
    fi
}

for agent in "$@"; do
    template=$(kube -n "$namespace" get agent "$agent" -o jsonpath='{.spec.template.ref.name}')
    references=$(kube -n "$namespace" get agenttemplate "$template" \
        -o jsonpath='{range .spec.tools[*]}{.mcp.server.name}{"\n"}{end}')
    expected_ref=no
    if [[ $'\n'"${references}"$'\n' == *$'\n'"${server}"$'\n'* ]]; then
        expected_ref=yes
    fi
    expect "$agent uses the authenticated MCP server" yes "$expected_ref"
    legacy_ref=no
    if [[ $'\n'"${references}"$'\n' == *$'\n'kagent-tool-server$'\n'* ]]; then
        legacy_ref=yes
    fi
    expect "$agent excludes the legacy MCP server" no "$legacy_ref"
done

servers=$(kube -n "$namespace" get remotemcpserver \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.url}{"\t"}{.spec.actorJwt.audiences[*]}{"\n"}{end}')
registration=$(awk -F '\t' -v name="$server" '$1 == name {print $2 "\t" $3}' <<< "$servers")
expect 'MCP URL and dedicated ActorJWT audience' "$proxy_url"$'\t'"$audience" "${registration:-absent}"

network_shape=$(kube -n "$namespace" get networkpolicy kagent-tools-ingress \
    -o jsonpath='{range .spec.ingress[*]}{range .from[*]}{.namespaceSelector}{":"}{.podSelector.matchLabels.app\.kubernetes\.io/name}{"\n"}{end}{end}')
expect 'backend ingress admits only the local proxy' ':kagent-mcp-auth' "$network_shape"

check_rbac() {
    local expected=$1 verb=$2 resource=$3 result status=0
    result=$(kube -n "$workload_namespace" auth can-i "$verb" "$resource" \
        --as="system:serviceaccount:${namespace}:kagent-tools") || status=$?
    if [[ $status -gt 1 || ( "$result" != yes && "$result" != no ) ]]; then
        printf 'Unable to check RBAC for %s %s\n' "$verb" "$resource" >&2
        exit 2
    fi
    expect "backend RBAC: $verb $resource" "$expected" "$result"
}

check_rbac yes get pods
check_rbac yes get pods/log
check_rbac no get secrets
check_rbac no patch deployments.apps

(( failures == 0 ))
