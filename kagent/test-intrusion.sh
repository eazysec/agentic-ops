#!/usr/bin/env bash
# Test d'intrusion du serveur d'outils kagent (kagent-tools), sur le cluster de banc « kagent ».
# But : mesurer si un pod SANS AUCUN DROIT peut lire un Secret d'un autre namespace via le serveur d'outils MCP.
# Sert 2 fois : AVANT durcissement (doit RÉUSSIR à lire = risque présent) et APRÈS (doit ÉCHOUER = risque traité).
# Rejouable : crée tout ce dont il a besoin et le défait, dans l'ordre inverse, avec un contrôle final.
# Usage : KUBECONFIG=~/kagent-lab/kubeconfig ./test-intrusion.sh
# Code retour : 0 si le secret N'EST PAS lisible (état durci attendu), 1 s'il l'est (risque présent).
set -uo pipefail
K="${KUBECTL:-kubectl137}"
NS_INTRUS=test-intrus-kagent
NS_CIBLE=test-cible-kagent
TEMOIN="TEMOIN-KAGENT-$(date +%s)"
MCP="http://kagent-tools.kagent.svc.cluster.local:8084/mcp"

nettoyer() {
    $K delete pod intrus -n "$NS_INTRUS" --ignore-not-found --wait=true >/dev/null 2>&1
    $K delete namespace "$NS_INTRUS" "$NS_CIBLE" --ignore-not-found --wait=true >/dev/null 2>&1
}
trap nettoyer EXIT

echo "== Préparation"
nettoyer
$K create namespace "$NS_INTRUS" >/dev/null
$K create namespace "$NS_CIBLE" >/dev/null
$K create secret generic secret-temoin -n "$NS_CIBLE" --from-literal=valeur="$TEMOIN" >/dev/null
echo "   secret témoin posé dans $NS_CIBLE ; valeur attendue (base64) : $(printf '%s' "$TEMOIN" | base64)"

# Pod intrus : aucun jeton de compte de service monté
$K run intrus -n "$NS_INTRUS" --image=curlimages/curl:8.11.1 --restart=Never \
   --overrides='{"spec":{"automountServiceAccountToken":false}}' --command -- sleep 600 >/dev/null
$K wait -n "$NS_INTRUS" --for=condition=Ready pod/intrus --timeout=120s >/dev/null
echo "   droits Kubernetes du pod intrus sur le secret : $($K auth can-i get secrets -n "$NS_CIBLE" --as=system:serviceaccount:"$NS_INTRUS":default)"

# Requêtes MCP depuis le pod : initialize, notifications/initialized, puis tools/call sur le secret
cat > /tmp/intrus-mcp.sh <<EOF
set -e
U="$MCP"; NS="$NS_CIBLE"
H1="-H Content-Type:application/json -H Accept:application/json,text/event-stream"
curl -s --max-time 20 -D /tmp/h -o /dev/null \$H1 \\
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' "\$U" || { echo "INJOIGNABLE"; exit 0; }
echo "initialize : \$(head -1 /tmp/h | tr -d '\r')"
S=\$(grep -i mcp-session-id /tmp/h | cut -d' ' -f2 | tr -d '\r')
[ -z "\$S" ] && { echo "pas de session (refusé)"; exit 0; }
curl -s -o /dev/null \$H1 -H "Mcp-Session-Id: \$S" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "\$U"
curl -s --max-time 20 \$H1 -H "Mcp-Session-Id: \$S" \\
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"k8s_get_resource_yaml\",\"arguments\":{\"resource_type\":\"secret\",\"resource_name\":\"secret-temoin\",\"namespace\":\"\$NS\"}}}" "\$U"
EOF
$K cp /tmp/intrus-mcp.sh "$NS_INTRUS"/intrus:/tmp/intrus-mcp.sh >/dev/null
sortie=$($K exec -n "$NS_INTRUS" intrus -- sh /tmp/intrus-mcp.sh 2>&1)
rm -f /tmp/intrus-mcp.sh /tmp/h
echo "== Réponse du serveur d'outils"
echo "$sortie" | grep -iE 'initialize|INJOIGNABLE|refusé|Forbidden|error' | head -3 | sed 's/^/   /'

echo "== Verdict"
if echo "$sortie" | grep -q "$(printf '%s' "$TEMOIN" | base64)"; then
    echo "   [RISQUE] le secret de $NS_CIBLE a été lu par un pod sans droits via kagent-tools"
    exit 1
else
    echo "   [OK] le secret n'a PAS été lu : l'accès au serveur d'outils est contrôlé"
    exit 0
fi
