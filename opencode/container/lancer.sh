#!/usr/bin/env bash
# Lance OpenCode dans le conteneur durci.
# Usage : ./lancer.sh                      interface plein écran
#         ./lancer.sh run --agent container-ops "demande"
#         ./lancer.sh --shell "commande"    exécute une commande dans le même conteneur durci (contrôles)
# Prérequis : image opencode-ops construite, cluster kind sur le réseau Docker « kind »,
#             configuration OpenCode installée dans ~/.config/opencode (install_opencode.sh).
set -euo pipefail
readonly IMAGE="opencode-ops:1.1.36"
readonly TRAVAIL="${TRAVAIL:-${HOME}/banc-travail}"
readonly ETAT="${HOME}/.opencode-conteneur"          # historique (pour trace-session.sh) et kubeconfig
# Config montée hors de /home/agent : sous ~/.config, OpenCode 1.1.36 nomme les agents
# « .config/opencode/agents/<nom> » et --agent <nom> ne les trouve plus (constaté au banc)
readonly CLUSTER_API="https://banc-control-plane:6443" # adresse du cluster vue depuis le réseau Docker « kind »
mkdir -p "$TRAVAIL" "$ETAT/historique"
# Jeton du compte de service en lecture seule, valable 8 h, régénéré à chaque lancement
jeton=$(kubectl create token opencode-lecture -n opencode-agent --duration=8h)
ca=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
umask 077
cat > "$ETAT/kubeconfig" <<KC
apiVersion: v1
kind: Config
clusters: [{name: banc, cluster: {server: ${CLUSTER_API}, certificate-authority-data: ${ca}}}]
users: [{name: opencode-lecture, user: {token: ${jeton}}}]
contexts: [{name: banc, context: {cluster: banc, user: opencode-lecture}}]
current-context: banc
KC
tty=(-i); [[ -t 0 ]] && tty=(-it)
entree=(); if [[ "${1:-}" == "--shell" ]]; then entree=(--entrypoint bash); set -- -c "$2"; fi
exec sg docker -c "$(printf '%q ' docker run --rm "${tty[@]}" "${entree[@]}" \
  --read-only --tmpfs /tmp --tmpfs /home/agent/.cache:uid=1000 --tmpfs /home/agent/.local/state:uid=1000 \
  --cap-drop ALL --security-opt no-new-privileges \
  --network kind \
  -v "$TRAVAIL":/travail \
  -v "$ETAT/historique":/home/agent/.local/share/opencode \
  -v "${HOME}/.config/opencode":/conf/opencode:ro -e XDG_CONFIG_HOME=/conf \
  -v "$ETAT/kubeconfig":/home/agent/.kube/config:ro \
  "$IMAGE" "$@")"
