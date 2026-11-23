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

## Identité et contrôle d’accès

### Authentification

Vérification de l’identité d’un appelant. Un service peut vérifier un jeton signé pour identifier l’appelant.

### Autorisation

Décision qui accorde ou refuse une action à une identité. Une politique d’accès précise quels appelants peuvent effectuer quelles actions sur quelles ressources.

### Fournisseur d’identité (IdP)

Service qui établit ou publie les éléments de confiance utilisés pour vérifier une identité. Dans une architecture à jetons, il peut publier les clés publiques de signature utilisées par les services destinataires.

### Audience d’un jeton

Identifiant d’un service ou d’un usage auquel un jeton est destiné. Le destinataire compare l’audience portée par le jeton à celle qu’il attend.

### JWKS

Ensemble de clés au format JSON Web Key Set. Dans le banc, l’IdP publie les clés publiques que le proxy utilise pour vérifier les signatures des jetons.

### [Agent Substrate] Actor

Instance d’exécution isolée qui porte une identité propre. Dans le banc kagent, un Actor exécute une session. Son identité apparaît dans le sujet du jeton sous une forme telle que `actor/kagent/session-…`.

### [Agent Substrate] ActorJWT

Jeton JWT signé par Agent Substrate qui atteste l’identité de l’Actor et indique son audience. La passerelle `atenet-egress` peut l’injecter dans une requête MCP. L’IdP Substrate publie les clés qui permettent au destinataire de le vérifier.

### [kagent] Agent

Ressource Kubernetes nommée qui associe une configuration `AgentTemplate` à un environnement d’exécution `Harness`. Dans le banc, `kagent/diag-lecture-gpt41` désigne l’Agent `diag-lecture-gpt41` dans le namespace `kagent`.

### [kagent] Contrôleur

Composant existant `kagent-controller` qui gère les agents et les sessions. Son API `ResolveAgentIdentity` permet de retrouver l’Agent rattaché à l’Actor d’une session à partir d’un jeton destiné à cette résolution.

## Découverte d’outils

### [MCP] Catalogue MCP

Liste des outils qu’un serveur annonce à un client en réponse à `tools/list`. Chaque entrée indique
le nom de l’outil et le schéma de ses paramètres. Elle peut aussi fournir une description. Par exemple,
une entrée peut annoncer `k8s_get_events` avec un paramètre `namespace` de type chaîne. L’appel
`tools/call` exécute ensuite l’outil et renvoie son résultat.
[Spécification MCP](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#listing-tools)
