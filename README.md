# Opencode

Installation et configuration d'OpenCode, client _"agentique"_ pour le développement assisté par IA en ligne de commande.

OpenCode est un agent IA open-source en ligne de commande qui peut interagir directement avec votre environnement: lire/modifier des fichiers, exécuter des commandes, analyser les erreurs et itérer jusqu'à résolution.

Sources:
- [GitHub OpenCode](https://github.com/anomalyco/opencode)
- [Deep dive technique](https://cefboud.com/posts/coding-agents-internals-opencode-deepdive/)

Termes employés (agent, sous-agent, session, permission...) : voir `termes.md` (dépôt privé).

Sommaire:

- [Architecture du banc d'essai (OpenCode et kagent)](#architecture-du-banc-dessai-opencode-et-kagent)
- [Introduction au codage agentique](#introduction-au-codage-agentique)
- [Installation](#installation)
- [Configuration des agents Ops](#configuration-des-agents-ops)
- [Exemples d'utilisation](#exemples-dutilisation)
- [Bonnes pratiques](#bonnes-pratiques)

## Architecture du banc d'essai (OpenCode et kagent)

Ce dépôt sert aussi de banc de comparaison entre **OpenCode** (agent sur le poste/conteneur) et **kagent** (agents dans
le cluster). Tout tourne sur **une seule instance EC2** (jetable, Spot, us-east-1), qui héberge Docker et **2 clusters
kind** indépendants. Le LLM (`gpt-oss-120b` et, pour comparaison, `gpt-4.1-mini`) est appelé chez **OpenRouter**, à
l'extérieur. Détails : `comparaison-opencode-kagent.md` (dépôt privé),
[kagent/securite-kagent.md](kagent/securite-kagent.md).

```
                        ┌──────────────────────────────────────────────────────┐
                        │  OpenRouter (LLM externe) gpt-oss-120b / gpt-4.1-mini │
                        └──────▲─────────────────────────────────────▲──────────┘
             HTTPS, LLM OpenCode│                    HTTPS, LLM agent kagent│ (par la passerelle)
   ┌───────────────────────────┼──────────────────────────────────────────┼──────────────────────┐
   │ INSTANCE EC2 (Docker)      │                                          │                      │
   │  ┌─────────────────────────┴────┐     ┌─────────────────────────────────┼────────────────────┐│
   │  │ OpenCode                     │     │ CLUSTER kind « kagent » (K8s 1.37)│                   ││
   │  │  • mode direct (hôte)        │     │   ns kagent          ns ate-system│                   ││
   │  │  • mode conteneur (durci :   │     │   ┌──────────┐       ┌────────────┴─┐                 ││
   │  │    non-root, RO, AppArmor)   │     │   │ agent    │──────►│ atenet-egress│ (passerelle,    ││
   │  └──────────────┬───────────────┘     │   │ (gVisor) │ toute │ (proxy :     │  sortie unique  ││
   │   kubectl (lecture,                   │   └──────────┘ sortie│  MCP + LLM)  │  du bac à sable)││
   │   compte opencode-lecture)            │                      └──┬───────────┘                 ││
   │                 ▼                     │       MCP/HTTP (saut 1) │                              ││
   │  ┌──────────────────────────────┐    │                         ▼                              ││
   │  │ CLUSTER kind « banc »         │    │   ┌──────────────┐  API K8s  ┌────────────────────┐   ││
   │  │ (K8s 1.31)                    │    │   │ kagent-tools │──────────►│ ns banc : pods      │   ││
   │  │  ns banc : pods panne+secret  │    │   │  :8084 (MCP) │  (saut 2) │ panne + secret-piege│   ││
   │  └──────────────────────────────┘    │   └──────────────┘           └────────────────────┘   ││
   │                                       │   NetworkPolicy : ingress 8084 depuis ns kagent +     ││
   │                                       │   pod atenet-egress (ate-system) ; tout le reste refusé││
   │                                       └───────────────────────────────────────────────────────┘│
   └────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Flux :**
- **OpenCode** parle au cluster `banc` par `kubectl` (lecture seule via le compte `opencode-lecture` en mode conteneur),
  et au LLM par HTTPS **direct** vers OpenRouter.
- **kagent, appels d'outils** : l'agent (bac à sable gVisor, ns `kagent`) atteint le serveur d'outils en **2 sauts** :
  saut 1 en MCP/HTTP via la passerelle `atenet-egress` (ns `ate-system`), saut 2 où `kagent-tools` appelle l'API
  Kubernetes avec son compte (c'est ce saut qui lit les ressources du ns `banc`).
- **kagent, raisonnement du modèle** : l'appel au LLM de l'agent sort **aussi** par `atenet-egress` vers OpenRouter,
  parce que le bac à sable force **toute** sa sortie (vers un service interne comme vers Internet) par cette passerelle.

**Filtrage et durcissement :**

| Cluster | Barrière principale | Barrière réseau |
|---------|---------------------|-----------------|
| `banc` (OpenCode) | RBAC `opencode-lecture` (lecture, sans Secrets) + conteneur durci | aucune |
| `kagent` | RBAC `kagent-tools` ramené en lecture seule sans Secrets | NetworkPolicy sur le port 8084 |

**Labels utilisés par la NetworkPolicy de kagent** (`kagent/hardening/networkpolicy.yaml`) :
- cible : pod `app.kubernetes.io/name: kagent-tools` ;
- autorisés en entrée sur 8084 : namespace `kubernetes.io/metadata.name: kagent`, **et** le pod `app: atenet-egress`
  du namespace `kubernetes.io/metadata.name: ate-system` (le chemin légitime des appels d'outils) ;
- tout le reste est refusé (vérifié : un pod d'un autre namespace tombe en timeout).

> Les 2 clusters sont séparés : `banc` (K8s 1.31) pour OpenCode, `kagent` (K8s 1.37, exigé par kagent 1.x) pour kagent.
> Chacun a son propre `kubectl` et son contexte ; kagent utilise un fichier de connexion dédié.

## Introduction au codage agentique

Pourquoi un agent de codage plutôt qu'une interface chat classique?

L'agent de codage peut effectuer des actions grâce aux outils de votre système. Ces outils transforment un LLM d'une simple interface chat en un acteur: il devient capable de lire des fichiers, d'exécuter des commandes, d'éditer du code, d'observer les résultats et d'itérer.

Avantages:
- Fin du copier-coller fastidieux: copier des snippets, des traces d'erreur et des fichiers dans un LLM est pénible, copier les suggestions ou modifications de code en retour l'est tout autant.
- Accès direct à l'environnement local: donner au LLM un accès direct à l'environnement local (et aux outils de développement) permet à l'agent de lancer une suite de tests après ses modifications, voir les résultats, réfléchir aux erreurs et ajuster en conséquence.
- Autonomie: une fois que le LLM a accès au code, aux outils et au feedback, on peut lui assigner une tâche et le laisser travailler.

Un agent unique avec tous les outils et toutes les permissions pose toutefois plusieurs problèmes:

1. Risque d'actions non désirées -> modification de fichiers ou exécution de commandes dangereuses
2. Contexte pollué -> un prompt système trop générique dilue l'attention du LLM sur ce qui est vraiment important pour la tâche en cours
3. Coût et efficacité -> Certaines tâches simples ne nécessitent pas un modèle puissant (et coûteux)

La solution est de spécialiser plusieurs agents avec des rôles, des outils et des permissions distincts.

#### Agents principaux: Plan, Build

OpenCode propose deux agents principaux par défaut:

| Agent | Rôle | Outils | Permissions |
|-------|------|--------|-------------|
| **Plan** | Analyse, exploration, planification | Lecture seule (`read`, `glob`, `grep`) | Ne peut pas modifier de fichiers, doit demander permission pour `bash` |
| **Build** | Implémentation, modification | Tous les outils | Peut éditer, écrire, exécuter |

Workflow typique:
1. On commence en mode **Plan** pour analyser le code et créer un plan d'action
2. On passe en mode **Build** pour exécuter le plan avec les modifications réelles

Cette séparation évite les modifications accidentelles pendant la phase d'exploration et force une réflexion avant l'action.

#### Sous-agents

En plus des agents principaux, OpenCode permet de définir des sous-agents spécialisés. Un agent principal peut invoquer un sous-agent via l'outil `task`, ou l'utilisateur peut l'appeler directement avec `@nom-agent`.

Avantages de la spécialisation:
- Chaque agent n'a accès qu'aux outils nécessaires à sa tâche
- Le prompt système est optimisé pour une tâche précise
- On peut utiliser des modèles plus petits (et donc moins coûteux en calcul) pour des tâches simples
- Plusieurs sous-agents peuvent travailler en parallèle sur des aspects différents
- Les configurations sont modulaires et réutilisables

Exemple d'orchestration:
```
Prompt : "Déploie la nouvelle version et vérifie qu'il n'y a pas de régression de sécurité"

Agent container-ops :
1. Met à jour le tag image dans le deployment
2. Applique avec kubectl
3. Appelle @security-audit pour scanner l'image
4. Vérifie les logs post-déploiement
5. Rollback si problème détecté
```

---

## Installation

```
git clone https://forge.acme.fr/acme/ops/tools/opencode.git
cd opencode
read -rs LLM_API_KEY && export LLM_API_KEY
bash kit/install_opencode.sh --base-url "https://api.llm:8080/v1" --proxy "http://proxy.infra.acme:3128"
cd .. && opencode
```

Le script :
1. Installe le binaire OpenCode
2. Configure la connexion à l'API LLM
3. Déploie les agents Ops personnalisés

## Configuration des agents Ops

Ce projet configure deux agents primaires distincts selon le périmètre d'intervention:

| Agent | Périmètre | Raccourci |
|-------|-----------|-----------|
| `container-ops` | Kubernetes, Helm, ArgoCD, observabilité applicative | Tab |
| `iaas-ops` | Terraform, Ansible, OpenStack, système, observabilité applicative | Tab |

### Sous-agents disponibles

Invocation via `@nom-agent` dans le prompt:
| Sous-agent | Usage | Appelable depuis |
|------------|-------|------------------|
| `@security-audit` | Audit de sécurité, scanning CVE, compliance | Les deux |
| `@troubleshoot` | Diagnostic de pannes, root cause analysis | Les deux |
| `@logs-analysis` | Analyse de logs, patterns d'erreurs | Les deux |
| `@iac-review` | Revue de code IaC, qualité, bonnes pratiques | Les deux |

Les sous-agents sont en lecture seule par défaut. Ils analysent et rapportent, mais ne modifient rien. C'est l'agent principal qui décide d'appliquer ou non les recommandations.

## Exemples d'utilisation

### Diagnostic d'un pod en erreur

```bash
opencode --prompt "Le pod cilium-xxx est en CrashLoopBackOff, diagnostique et propose une correction"
```

L'agent va :
1. `kubectl describe pod cilium-xxx`
2. `kubectl logs cilium-xxx --previous`
3. Analyser les erreurs (OOMKilled? Config manquante? Image introuvable?)
4. Proposer un correctif (edit du deployment ou de la configmap)

### Revue d'un role Ansible

```bash
opencode --prompt "@iac-review Analyse le role ansible nginx et vérifie les bonnes pratiques"
```

### Analyse post-incident

```bash
opencode --prompt "@logs-analysis Cherche les erreurs 4xx et 5xx dans les logs haproxy entre 14h et 15h et propose une diagnostique"
```

### Audit de sécurité

```bash
opencode --prompt "@security-audit Scanne l'image docker app:v2.1.0 et liste les CVE critiques"
```

---

## Bonnes pratiques

1. Commencer en mode Plan
2. Utiliser les sous-agents spécialisés
3. Vérifier avant d'appliquer, OpenCode demande confirmation pour les commandes destructives, lisez avant de valider
4. Itérer par petites étapes, décomposer en sous-tâches plutôt qu'un prompt complexe 