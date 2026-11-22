#!/usr/bin/env bash
# Verify that a normal pod in the previously allowed namespace cannot reach port 8084.
set -euo pipefail
: "${KUBECONFIG:?Set KUBECONFIG to the kagent cluster kubeconfig}"
kubectl_bin=${KUBECTL:-kubectl137}
namespace=${KAGENT_NAMESPACE:-kagent}
backend=${MCP_BACKEND_URL:-http://kagent-tools.$namespace.svc.cluster.local:8084/healthz}
probe="actorjwt-network-check-$(date +%s)-$$"

kube() { "$kubectl_bin" --request-timeout=10s -n "$namespace" "$@"; }

kube run "$probe" --restart=Never --image=curlimages/curl:8.11.1 \
    --overrides='{"spec":{"automountServiceAccountToken":false}}' \
    --command -- sh -ec '
        status=0
        http=$(curl --noproxy "*" --connect-timeout 3 --max-time 5 -sS -o /dev/null -w "%{http_code}" "$1") || status=$?
        printf "transport=%s http=%s\n" "$status" "$http"
        test "$status" = 28 && test "$http" = 000
    ' sh "$backend" >/dev/null
trap 'kube delete pod "$probe" --ignore-not-found -o name >/dev/null' EXIT

for ((attempt=0; attempt<30; attempt++)); do
    phase=$(kube get pod "$probe" -o jsonpath='{.status.phase}')
    case "$phase" in
        Succeeded) kube logs "$probe"; exit 0 ;;
        Failed) kube logs "$probe" >&2; exit 1 ;;
    esac
    sleep 1
done
printf 'Network probe did not finish\n' >&2
exit 1
