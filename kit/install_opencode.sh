#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
readonly VERSION="1.1.36"
readonly GITHUB_BASE_URL="https://github.com/anomalyco/opencode/releases/download"
readonly BIN_DIR="/usr/local/bin"
readonly BIN_NAME="opencode"
readonly DEFAULT_MODEL="Gpt-oss-120b"
readonly DEFAULT_LLM_BASE_URL="http://localhost:11434/v1"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="${HOME}/.config/opencode"

WORKDIRS=()
LLM_BASE_URL=""
LLM_MODEL=""
PROXY=""
SHA256=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

La cle API est lue dans la variable LLM_API_KEY, sinon demandee au clavier
(jamais en argument : elle resterait dans l'historique et dans ps).

Options:
    -u, --base-url URL      URL de base LLM (defaut: $DEFAULT_LLM_BASE_URL)
    -m, --model ID          Identifiant du modele chez le fournisseur (defaut: $DEFAULT_MODEL)
    -p, --proxy URL         Proxy HTTP(S) pour le telechargement (defaut: aucun, ou celui de l'environnement)
    -s, --sha256 SOMME      Somme SHA-256 attendue de l'archive (recommande)
    -h, --help              Affiche cette aide

Exemple:
    read -rs LLM_API_KEY && export LLM_API_KEY
    $(basename "$0") --base-url "https://api.example.com/v1" --proxy "http://proxy:3128"
USAGE
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--base-url) LLM_BASE_URL="$2"; shift 2 ;;
            -m|--model)    LLM_MODEL="$2";    shift 2 ;;
            -p|--proxy)    PROXY="$2";        shift 2 ;;
            -s|--sha256)   SHA256="$2";       shift 2 ;;
            -k|--api-key)  echo "Erreur: --api-key supprime, utiliser la variable LLM_API_KEY" >&2; exit 1 ;;
            -h|--help)     usage ;;
            *) echo "Option inconnue: $1" >&2; usage ;;
        esac
    done
    LLM_BASE_URL="${LLM_BASE_URL:-$DEFAULT_LLM_BASE_URL}"
    LLM_MODEL="${LLM_MODEL:-$DEFAULT_MODEL}"
    if [[ -z "${LLM_API_KEY:-}" ]]; then
        read -rsp "Cle API LLM : " LLM_API_KEY; echo
    fi
    [[ -n "$LLM_API_KEY" ]] || { echo "Erreur: cle API vide" >&2; exit 1; }
}

cleanup() {
    for dir in "${WORKDIRS[@]}"; do [[ -d "$dir" ]] && rm -rf "$dir"; done
}
trap cleanup EXIT

make_workdir() {
    local dir; dir=$(mktemp -d -t opencode-XXXXXX); WORKDIRS+=("$dir"); echo "$dir"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)        echo "x64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "Erreur: architecture $(uname -m) non geree" >&2; exit 1 ;;
    esac
}

# Remplace une chaine litterale dans un fichier, quels que soient ses caracteres
replace_literal() {
    local file="$1" from="$2" to="$3" content
    content=$(<"$file")
    printf '%s\n' "${content//"$from"/"$to"}" > "$file"
}

install_binary() {
    local workdir tar_name download_url binary_path
    tar_name="opencode-linux-$(detect_arch).tar.gz"
    download_url="${GITHUB_BASE_URL}/v${VERSION}/${tar_name}"
    workdir=$(make_workdir)

    echo "Installation d'OpenCode v${VERSION} (${tar_name})"
    if [[ -n "$PROXY" ]]; then export http_proxy="$PROXY" https_proxy="$PROXY"; fi
    wget -q --show-progress -O "${workdir}/${tar_name}" "$download_url"

    if [[ -n "$SHA256" ]]; then
        echo "${SHA256}  ${workdir}/${tar_name}" | sha256sum -c - >/dev/null \
            || { echo "Erreur: somme SHA-256 differente de celle attendue" >&2; exit 1; }
        echo "Somme SHA-256 verifiee"
    else
        echo "Avertissement: archive non verifiee (option --sha256 absente)" >&2
    fi

    tar -xzf "${workdir}/${tar_name}" -C "$workdir"
    binary_path=$(find "$workdir" -type f -executable -name "$BIN_NAME" -print -quit)
    [[ -n "$binary_path" ]] || { echo "Erreur: binaire '$BIN_NAME' introuvable dans l'archive" >&2; exit 1; }

    sudo install -Dm755 "$binary_path" "${BIN_DIR}/${BIN_NAME}"
    echo "Binaire installe dans ${BIN_DIR}"
}

install_config() {
    local config_file="${CONFIG_DIR}/opencode.json" f
    [[ -d "${SCRIPT_DIR}/agents" ]]        || { echo "Erreur: dossier agents/ introuvable" >&2; exit 1; }
    [[ -f "${SCRIPT_DIR}/config/opencode.json" ]] || { echo "Erreur: config/opencode.json introuvable" >&2; exit 1; }

    mkdir -p "${CONFIG_DIR}/agents"
    cp -r "${SCRIPT_DIR}/agents/." "${CONFIG_DIR}/agents/"
    install -m600 "${SCRIPT_DIR}/config/opencode.json" "$config_file"

    replace_literal "$config_file" "{{LLM_API_KEY}}"  "$LLM_API_KEY"
    replace_literal "$config_file" "{{LLM_BASE_URL}}" "$LLM_BASE_URL"
    if [[ "$LLM_MODEL" != "$DEFAULT_MODEL" ]]; then
        replace_literal "$config_file" "$DEFAULT_MODEL" "$LLM_MODEL"
        for f in "${CONFIG_DIR}"/agents/*.md; do replace_literal "$f" "local/${DEFAULT_MODEL}" "local/${LLM_MODEL}"; done
    fi
    echo "Configuration installee dans ${config_file} (droits 600)"
}

main() {
    parse_args "$@"
    echo "Base URL: ${LLM_BASE_URL}"
    echo "Modele  : ${LLM_MODEL}"
    install_binary
    install_config
    echo "Installation terminee"
}

main "$@"
