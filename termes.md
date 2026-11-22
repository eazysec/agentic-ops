# Termes

## Agents OpenCode

### Agent

Configuration qui donne un rôle au modèle. Elle précise ses consignes, les outils qu’il peut utiliser et les permissions qui encadrent leur usage. Dans ce kit, `container-ops` et `iaas-ops` sont les deux agents principaux.

### Sous-agent

Agent auquel un agent principal confie une tâche ciblée. Dans ce kit, `troubleshoot`, `logs-analysis`, `security-audit` et `iac-review` sont configurés pour analyser et transmettre leurs observations. L’agent principal s’appuie sur ces résultats pour proposer une correction.

### Délégation

Appel d’un sous-agent par un agent principal via l’outil `task`. La délégation peut être demandée par l’utilisateur ou décidée par l’agent principal pendant son investigation. Par exemple, `container-ops` peut demander à `logs-analysis` de rechercher la première erreur qui précède le redémarrage d’un pod, puis rapprocher le résultat des événements Kubernetes.

### Profil d’agent

Dans ce kit, fichier Markdown qui décrit la configuration d’un agent. L’en-tête indique notamment son mode (`primary` ou `subagent`), le modèle et les permissions déclarées. Le corps du fichier contient les consignes métier. Par exemple, [le profil de `container-ops`](opencode/agents/container-ops.md) décrit comment diagnostiquer un incident Kubernetes. Plusieurs profils peuvent utiliser le même modèle avec des consignes différentes.
