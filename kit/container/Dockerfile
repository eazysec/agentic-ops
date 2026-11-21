# Image OpenCode Ops : outils en versions figées, utilisateur non root.
# Construite et testée sur le banc (voir docs/references/journal-commandes.md (dépôt privé)).
FROM ubuntu:24.04

ARG OPENCODE_VERSION=1.1.36
ARG KUBECTL_VERSION=v1.31.2
ARG HELM_VERSION=v3.16.2
ARG TERRAFORM_VERSION=1.9.8

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl unzip git jq python3 ansible ansible-lint \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; t=$(mktemp -d); cd "$t"; \
    curl -fsSLo kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz; \
    curl -fsSLo tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" && unzip -q tf.zip; \
    curl -fsSL "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" | tar -xz; \
    install -m755 kubectl linux-amd64/helm terraform "$(find . -type f -name opencode -perm -u+x | head -1)" /usr/local/bin/; \
    cd /; rm -rf "$t"

# Utilisateur sans droits ; dossier de travail et historique montés en volumes au lancement
RUN userdel -r ubuntu 2>/dev/null || true; useradd -m -u 1000 -s /bin/bash agent \
 && mkdir -p /travail /home/agent/.local/share/opencode /home/agent/.config/opencode \
 && chown -R agent:agent /travail /home/agent
COPY --chown=root:root tools/trace-session.sh /usr/local/bin/trace-session.sh
USER agent
WORKDIR /travail
ENTRYPOINT ["opencode"]
