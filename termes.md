# Termes

## Architecture de référence

Le schéma de référence suit une demande utilisateur jusqu’au modèle, aux données et aux outils que
l’agent peut appeler. Il situe les contrôles sur chaque flux, depuis la validation des entrées
jusqu’à la décision d’accès et aux traces de l’action. [Architecture de sécurité d’un agent IA](https://securite-agentique.fr/architecture-securite-agent-ia)

| Composant du schéma | Équivalent dans agentic-ops |
|---|---|
| **Utilisateur et agent** | L’opérateur utilise l’interface kagent ou la CLI OpenCode. Dans kagent, un Actor exécute la session d’un Agent. Dans OpenCode, un profil comme `container-ops` configure le modèle et ses outils. |
| **Input Guard** · contrôle des entrées utilisateur | Contrôle de contenu dédié à prévoir pour les prompts et les pièces jointes. L’authentification de l’accès humain à l’interface kagent est un sujet distinct. |
| **Output Guard** · contrôle des réponses utilisateur | Contrôle de contenu dédié à prévoir avant la restitution de la réponse. |
| **LLM** | OpenRouter fournit l’accès au modèle externe et Ollama sert le modèle interne du banc. Un mock provider LLM reçoit les requêtes de l’expérience de filtrage. |
| **LLM Guard** · contrôle du contexte transmis au modèle | Couverture ciblée dans la fiche 05. Le collecteur de test `collecteur.py` sélectionne `error_code` à la sortie de l’outil, avant que le résultat atteigne OpenCode et le modèle. |
| **MCP Guard** · contrôle des échanges avec les outils | Couverture partielle. Le proxy [`kagent-mcp-auth`](kagent/hardening/actorjwt/gateway.yaml) authentifie l’Actor et protège l’accès au serveur. L’inspection des arguments et des champs retournés reste un contrôle distinct. |
| **Serveur MCP** | [`kagent-tools`](docs/references/securite-kagent.md#authentification-du-flux-mcp-avec-actorjwt) expose les outils Kubernetes et exécute leurs appels avec son propre compte de service. |
| **PEP** · point d’application de la décision | `kagent-mcp-auth` appelle `authorizer`, puis applique sa décision avant de transmettre ou de refuser la requête MCP. |
| **PDP** · point de décision | Le conteneur [`authorizer`](kagent/hardening/actorjwt/authorizer/main.go) décide selon le namespace et le nom de l’Agent. |
| **PIP** · source d’attributs | `kagent-controller` fournit l’identité de l’Agent associé à la session via `ResolveAgentIdentity`. L’IdP Substrate fournit séparément les clés publiques pour vérifier le JWT. |
| **PAP** · administration de la politique | La politique est maintenue dans Git, dans [`allowed-agents`](kagent/hardening/actorjwt/allowed-agents), puis appliquée avec les manifestes du proxy. Le banc utilise ce workflow pour administrer la liste. |
| **Web Guard** · contrôle des accès Internet | `atenet-egress` est le point de sortie des Actors kagent, notamment vers OpenRouter. Il assure ce passage réseau. Un contrôle du contenu Web serait une fonction supplémentaire. |
| **PEP RAG et base documentaire RAG** | Hors périmètre du banc actuel. |
| **API Gateway, API interne et contrôle applicatif** | Pour la cible Kubernetes, l’API applique le [RBAC](kagent/hardening/rbac.yaml) du compte `kagent-tools`. Les API métier et leurs règles applicatives sont hors périmètre du banc. |
| **DevSecOps Guard et CI/CD** | La préparation de corrections via PR et leur exécution dans une CI avec approbation figurent parmi les évolutions du projet. |
| **Isolation de l’exécution** | Les sessions kagent s’exécutent dans un Actor isolé par gVisor. OpenCode dispose d’un [lanceur en conteneur durci](opencode/container/lancer.sh). |
| **Journaux et signaux** | Les traces du proxy identifient l’Actor et le statut HTTP. Les logs d’`authorizer` indiquent l’Agent résolu et la décision. Les [tests de session](kagent/tests/actorjwt/test-actorjwt-session.sh) relient la trace du proxy au résultat MCP. |
| **Leurre de détection** | Le Secret synthétique [`secret-piege`](bench/scenarios/outages.yaml) est un témoin de test du refus de lecture. Une intégration de détection et d’alerte de type Trapster reste à mettre en place. |
| **SOC, SIEM, SOAR et réponse** | Le banc exploite les journaux pour les vérifications et les démonstrations. La corrélation centralisée et la réponse automatisée restent hors périmètre. |

Sur le flux MCP, `atenet-egress` injecte le jeton, le proxy valide l’identité de l’Actor et
`authorizer` décide si l’Agent peut appeler `kagent-tools`. Une fois la requête transmise,
Kubernetes vérifie les droits du compte de service de `kagent-tools`. La fiche 04 vérifie ce
périmètre avec un compte de test dédié. La fiche 05 vérifie ensuite une autre propriété, celle
des champs effectivement remis au modèle pour une lecture autorisée. [Schémas du banc](README.md#architecture-du-banc-dessai-opencode-et-kagent) · [Note de sécurité](docs/references/securite-kagent.md)

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
