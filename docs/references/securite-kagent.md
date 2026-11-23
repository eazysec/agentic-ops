# Sécurité de kagent sur le banc : test d'intrusion et durcissement

Ce document décrit un risque de sécurité **constaté** sur une installation de kagent 1.0.1 par défaut (voie CLI),
le **test rejouable** qui le prouve, et les **mesures de durcissement** pour le traiter.

> Cadre : banc d'essai jetable, cluster kind `kagent`, aucun secret réel, aucun environnement de production.
> Le banc compare aussi cette architecture avec OpenCode en conteneur. [Vue d’ensemble du banc](../../README.md)

## 1. Contexte

kagent fait tourner ses agents **dans** le cluster. Ses outils Kubernetes sont exposés par un serveur,
`kagent-tools`, via le protocole MCP (Model Context Protocol : façon standard de brancher des outils sur un modèle).
Un agent appelle le serveur, le serveur exécute l'action sur le cluster avec **son** compte de service.

La sécurité repose donc sur 3 choses, indépendantes les unes des autres :
1. les droits Kubernetes (RBAC) du compte de service du serveur d'outils ;
2. qui peut joindre le serveur d'outils sur le réseau ;
3. les garde-fous propres à kagent (liste d'outils par agent, validation humaine).

Le point 3 ne protège que le chemin **agent → outil**. Il ne protège pas un appel **direct** au serveur d'outils.

### Le chemin d’un appel d’outil avant ActorJWT

`kagent-tools` n'est pas le client qui demande, c'est le **serveur qui exécute** : il détient le compte de service
(par défaut, administrateur du cluster) et appelle l'API Kubernetes. L'agent est le **client**.

```
  ns kagent                         ns ate-system            ns kagent                    API du cluster
┌───────────────┐   MCP / HTTP   ┌───────────────┐  MCP/HTTP ┌──────────────┐  API K8s  ┌──────────────────┐
│ agent (worker │ ─────────────► │ atenet-egress │ ────────► │ kagent-tools │ ────────► │ ressources :     │
│ gVisor,       │   SAUT 1       │ (passerelle   │   SAUT 1  │  :8084       │  SAUT 2   │ pods, secrets... │
│ session)      │                │  de sortie)   │           │ (serveur MCP)│           │ (ns banc, etc.)  │
└───────────────┘                └───────────────┘           └──────────────┘           └──────────────────┘
      client                     (car l'agent est         détient le compte de         accès réel aux données
                                  en bac à sable)          service et ses droits
```

- **Saut 1** (agent → serveur d'outils) : en HTTP, **sans authentification**. Il passe par `atenet-egress` parce que
  l'agent tourne en bac à sable gVisor : ce bac à sable n'a pas de réseau de pod normal, et **toute** sa sortie (même
  vers un service du même namespace, même vers OpenRouter) est forcée par la passerelle du Substrate, qui y applique
  filtrage, identité (mTLS) et inspection.
  Point important pour le filtrage : `atenet-egress` n'est pas un simple relais, elle **termine la connexion de l'agent
  et en ouvre une nouvelle** vers `kagent-tools`. La connexion qui arrive sur le port 8084 a donc pour **source réelle le
  pod `atenet-egress` (ns `ate-system`)**, pas le pod de l'agent. Une NetworkPolicy filtre sur cette source réelle : c'est
  pourquoi « autoriser le ns `kagent` seulement » bloque l'agent (sa connexion arrive estampillée `ate-system`), et
  pourquoi il faut autoriser le pod `atenet-egress`. Mesuré : règle « `kagent` seulement » → l'agent perd ses outils
  (« failed to discover MCP tools ») ; règle incluant la passerelle → outils retrouvés.
- **Saut 2** (serveur d'outils → API Kubernetes) : `kagent-tools` est un pod normal, il parle directement à l'API,
  avec **son** compte de service. C'est ce saut qui lit ou modifie réellement les ressources.

Conséquences pour le durcissement :
- les **ressources visées** (secret `banc`) ne sont pas « dans un namespace séparé » atteint par la passerelle :
  elles sont atteintes au saut 2, via l'API, avec les droits de `kagent-tools`. **D'où le RBAC (durcissement 1)** ;
- un pod intrus qui atteint le port 8084 (saut 1) fait exécuter n'importe quel outil par `kagent-tools` : **d'où la
  NetworkPolicy (durcissement 2)**, qui doit autoriser `kagent` et la passerelle `atenet-egress`, et refuser le reste.

### Contrôles en place avant ActorJWT

Dans l’installation par défaut testée, `kagent-tools` acceptait les requêtes MCP sans
authentification et utilisait un compte de service doté de droits d’administration sur le cluster.
Le premier durcissement a réduit ces droits à la lecture, avec exclusion des Secrets. Cette limite
s’applique à chaque opération que le serveur demande à l’API Kubernetes.

La `NetworkPolicy` mise en place à cette étape limitait l’accès au port 8084 aux pods du namespace
`kagent` et à la passerelle `atenet-egress` du namespace `ate-system`. Les appels des Agents
arrivaient depuis cette passerelle. La politique pouvait filtrer cette source réseau, mais le
serveur acceptait encore les requêtes des sources autorisées sans vérifier l’identité de l’Agent.

La liste d’outils `mcp.tools` et la validation humaine `requireApproval` encadrent les appels
gérés par kagent. Une requête qui atteint directement le serveur MCP échappe à ces règles côté
client. Ses opérations Kubernetes restent soumises au RBAC du compte de service de `kagent-tools`.

## 2. Risque constaté (installation par défaut, 2026-11-21)

| Observation | Mesure |
|-------------|--------|
| Droits du compte `kagent-tools` | ClusterRole `kagent-tools-cluster-admin-role` = `apiGroups:[*] resources:[*] verbs:[*]` + `nonResourceURLs:[*]` : **administrateur complet du cluster** |
| Accès réseau au serveur d'outils | HTTP simple sur `kagent-tools.kagent.svc.cluster.local:8084`, **sans authentification** |
| Filtrage réseau (NetworkPolicy) dans le namespace `kagent` | **aucune** (le namespace `ate-system`, lui, en a, dont `default-deny-ingress`) |

Conséquence : **tout pod du cluster** peut appeler le serveur d'outils et agir en administrateur, sans aucun droit propre.

## 3. Test d'intrusion rejouable

Script : [test-intrusion.sh](../../kagent/test-intrusion.sh). Il mesure si un pod **sans aucun droit** lit un Secret d'un autre namespace via `kagent-tools`.

Démarche :
1. créer 2 namespaces jetables : `test-intrus-kagent` (l'attaquant), `test-cible-kagent` (la victime) ;
2. poser dans la cible un Secret témoin à valeur unique ;
3. lancer dans le namespace intrus un pod `curl` **sans jeton de compte de service** (`automountServiceAccountToken:false`) ;
4. vérifier que ce pod n'a **aucun droit** Kubernetes sur le secret (`kubectl auth can-i` → `no`) ;
5. depuis ce pod, parler au serveur d'outils en MCP : `initialize`, puis `tools/call` de `k8s_get_resource_yaml` sur le secret ;
6. **verdict** : le secret apparaît-il dans la réponse ?
7. tout défaire (pod, secret, namespaces) dans l'ordre inverse, et contrôler qu'il ne reste rien.

Lancement :

```bash
# Sélectionner le kubeconfig du cluster kagent avant de lancer la commande.
./kagent/test-intrusion.sh ; echo "code=$?"
```

Lecture du résultat (c'est un **test négatif** : il doit échouer avant le durcissement) :

| Code retour | Sens |
|-------------|------|
| `1` + `[RISQUE] le secret ... a été lu` | le serveur d'outils est joignable sans contrôle : **risque présent** (état par défaut) |
| `0` + `[OK] le secret n'a PAS été lu` | l'accès est contrôlé : **risque traité** (état attendu après durcissement) |

Résultats mesurés (2026-11-21) : **avant durcissement**, code `1`, le secret témoin rendu en clair (base64 identique),
alors que le pod n'avait aucun droit ; **après durcissement** (partie 4), code `0`, lecture refusée. Le nettoyage ne laisse aucune trace (contrôle indépendant).

## 4. Mesures de durcissement

Les étapes ci-dessous décrivent le premier durcissement, avant ActorJWT. Pour installer l’état actuel du banc,
suivre [l’ordre de déploiement dans le README](../../README.md#kagent--installation-et-exemples).

Objectif : que le test de la partie 3 passe de `1` à `0`, sans empêcher un agent de diagnostiquer.

1. **RBAC en lecture seule, sans Secrets.** Remplacer `kagent-tools-cluster-admin-role` par un ClusterRole de lecture
   qui n'inclut pas la ressource `secrets` (même principe que le compte `opencode-lecture` du banc OpenCode).
   L'agent peut encore lire pods, événements, déploiements, logs, mais plus les Secrets, et ne peut plus écrire.
2. **Filtrage réseau (NetworkPolicy).** N'autoriser à joindre le port 8084 de `kagent-tools` que ce qui en a besoin,
   et refuser tout le reste. **Attention au chemin de sortie** : dans kagent 1.x, les appels d'outils d'un agent ne
   partent pas de son pod, ils sortent par la passerelle `atenet-egress` du namespace `ate-system` (Agent Substrate).
   Une politique « namespace `kagent` seulement » casse donc l'agent (symptôme : « failed to discover MCP tools »,
   l'agent perd ses outils). Il faut autoriser le namespace `kagent` **et** le pod `atenet-egress` d'`ate-system`.
3. **Rejouer le test** de la partie 3 : il doit renvoyer `0`.
4. **Vérifier qu'un agent fonctionne encore** : un diagnostic de panne doit aboutir avec les droits réduits.

> Leçon (constatée au banc) : durcir un agent qui tourne **dans** le cluster oblige à connaître son architecture de
> sortie. Une NetworkPolicy écrite « à l'instinct » bloque le chemin légitime en même temps que l'intrus. Le RBAC,
> lui, est indépendant du réseau : c'est pourquoi il reste la barrière principale.

Le [manifeste RBAC](../../kagent/hardening/rbac.yaml) est toujours utilisé. La
[politique réseau suivie dans le dépôt](../../kagent/hardening/networkpolicy.yaml) correspond désormais
à l’état après la bascule ActorJWT.

### Résultats mesurés à date du commit

Le tableau compare l’installation par défaut au premier durcissement RBAC et réseau, avant l’ajout d’ActorJWT.
Les vérifications effectuées après la bascule ActorJWT figurent dans la section suivante.

| Contrôle | Avant | Après |
|----------|-------|-------|
| `kagent-tools` peut tout faire (`*`,`*`) | oui | **non** |
| `kagent-tools` peut lire les Secrets | oui | **non** |
| `kagent-tools` peut lire les pods (diagnostic) | oui | oui (conservé) |
| `kagent-tools` peut supprimer des pods | oui | **non** |
| test d'intrusion (secret lu par un pod sans droits) | **code 1, lu** | **code 0, refusé** |
| port 8084 joignable depuis un autre namespace | oui | **non** (timeout) |
| port 8084 joignable depuis le namespace `kagent` | oui | oui (conservé) |
| pods kagent en panne après durcissement | (sans objet) | aucun |

La NetworkPolicy est **appliquée par kindnet** sur ce cluster (sonde externe en timeout, sonde interne joignable).
Tous les CNI ne l'appliquent pas : le RBAC (lecture seule, sans Secrets) reste la barrière indépendante du réseau.

> Réseau du cluster : **kindnet** (le réseau par défaut de kind), sur le banc `kagent` comme sur `banc`. Cilium n'est
> installé nulle part ; la ligne `cilium *` des agents OpenCode est une autorisation de commande, pas un composant.
> En production, un CNI comme Cilium permettrait un filtrage plus fin (au niveau du chemin HTTP, p. ex. limiter à `/mcp`).

Limite connue : ces changements sont appliqués dans le cluster, mais le chart Helm de kagent peut les réécrire lors
d'une mise à jour. La bonne place est un fichier de valeurs du chart, si le chart l'autorise (à vérifier).

## Authentification du flux MCP avec ActorJWT

**ActorJWT protège le flux de l’Agent vers `kagent-tools`.** Le proxy MCP utilise ce jeton pour
authentifier l’Actor qui exécute la session. L’accès de l’utilisateur à l’interface kagent et au
contrôleur relève d’un contrôle distinct.

Le flux passe par deux instances distinctes d’AgentGateway.

- **`atenet-egress`** est la passerelle de sortie d’Agent Substrate. Elle obtient le JWT de l’Actor et l’ajoute à la requête MCP.
- **`kagent-mcp-auth`** est le proxy à l’entrée de `kagent-tools`. Il valide le JWT et applique
  la décision d’autorisation avant de transmettre la requête.

Agent Substrate exécute les sessions kagent dans des Actors et émet leurs jetons. Son fournisseur
d’identité, le service `idp` du namespace `ate-system`, publie les clés publiques de signature (JWKS).
[Glossaire](../../termes.md#identité-et-contrôle-daccès)

```text
Dépendances d’identité
  atenet-egress  → API Agent Substrate   obtient le JWT de l’Actor
  kagent-mcp-auth → IdP Substrate        récupère les clés publiques en HTTPS

Trajet d’un appel MCP
  Actor → atenet-egress → kagent-mcp-auth → kagent-tools:8084 → API Kubernetes
                          valide le JWT   reçoit l’appel       applique le RBAC
                          et consulte     sans le JWT
                          authorizer
```

Le `RemoteMCPServer` pointe vers le proxy et demande un jeton destiné à l’audience MCP
`kagent-tools-mcp`. Le proxy vérifie la signature, l’émetteur, l’audience et l’expiration. Pour récupérer
les clés de l’IdP en HTTPS, il utilise le bundle de confiance Kubernetes des certificats DNS de Substrate.
Les appels MCP internes du banc utilisent HTTP.

La politique réseau réserve l’accès à `kagent-tools:8084` aux pods du proxy. Après la décision
d’autorisation MCP, le RBAC du compte `kagent-tools` borne les opérations auprès de Kubernetes.
[Manifestes de déploiement](../../kagent/hardening/actorjwt/) · [Tests de validation](../../kagent/tests/actorjwt/)

[Injection ActorJWT dans kagent](https://github.com/kagent-dev/kagent/pull/3359) · [Vérification des jetons Substrate](https://ate.dev/docs/guides/actor-jwts/)

## Autorisation du flux MCP par Agent kagent

Le pod `kagent-mcp-auth` contient deux conteneurs. [`proxy.yaml`](../../kagent/hardening/actorjwt/proxy.yaml)
démarre le conteneur `gateway` avec l’argument `-f /etc/agentgateway/gateway.yaml`.
Dans [`gateway.yaml`](../../kagent/hardening/actorjwt/gateway.yaml), `jwtAuth` valide le jeton,
puis `extAuthz` consulte le conteneur `authorizer` sur `127.0.0.1:8090/check`. Le service Kubernetes
expose uniquement le port MCP du proxy.

- **`kagent-controller`** gère les Agents et leurs sessions. Son API `ResolveAgentIdentity` retrouve
  l’Agent associé à l’Actor de la session.
- **`authorizer`** compare le namespace et le nom renvoyés par le contrôleur à la liste
  [`allowed-agents`](../../kagent/hardening/actorjwt/allowed-agents), puis répond au proxy.

```text
Actor → atenet-egress → kagent-mcp-auth
                          │ Valide le JWT avec les clés de l’IdP Substrate
                          │ Consulte authorizer et reçoit sa décision
                          │   └─ authorizer → kagent-controller / ResolveAgentIdentity
                          │                   renvoie le namespace et le nom de l’Agent
                          └─→ kagent-tools → API Kubernetes, si l’Agent est autorisé
```

Le `RemoteMCPServer` demande aussi l’audience `kagent-agent-info` pour la résolution d’identité.
Le proxy conserve le JWT le temps de consulter `authorizer`. Celui-ci le présente à
`kagent-controller` sur son service gRPC interne, en HTTP/2 sans TLS sur ce banc. Si la décision est
favorable, le proxy retire l’en-tête `Authorization` et transmet lui-même la requête à `kagent-tools`.

| Situation | Résultat |
|---|---|
| Jeton absent ou invalide | HTTP 401 à la validation par le proxy |
| Jeton valide, Agent hors liste | HTTP 403 après résolution de l’identité |
| Échec de résolution | Requête bloquée. Le test isolé a observé HTTP 503. |
| Agent autorisé | Requête transmise à `kagent-tools`. L’API Kubernetes applique le RBAC de son compte. |

La politique compare le namespace et le nom de l’Agent, sans épingler son UID. Les décisions sont
prises à chaque requête sans cache.

[API de résolution d’identité kagent](https://github.com/kagent-dev/kagent/pull/3362)

## 5. À retenir

- **kagent-tools fixe le périmètre Kubernetes des appels transmis.** Sur le banc, son compte de service peut
  lire les pods et leurs logs, et Kubernetes refuse la lecture directe des Secrets ainsi que la modification des
  Deployments. Les logs et les ConfigMaps restent des sources potentiellement sensibles. La liste d’outils
  d’un agent intervient côté client, tandis que le RBAC s’applique aux opérations du serveur.
- **La protection du flux MCP combine deux contrôles distincts.** Le proxy a refusé une requête sans jeton
  avec HTTP 401, et les deux agents ont lu les événements via le parcours authentifié. Une sonde distincte
  a confirmé le blocage du port direct depuis un pod du namespace `kagent` auparavant autorisé. Le test
  du proxy sur backend factice a aussi couvert les jetons invalides et vérifié que le jeton valide est retiré
  avant transmission.
- **ActorJWT authentifie l’Actor de la session.** La configuration du banc valide l’émetteur et l’audience.
  Le contrôle d’accès vérifie en plus l’Agent rattaché à la session. Les deux agents autorisés partagent
  le compte Kubernetes de `kagent-tools`. Des droits Kubernetes distincts exigeraient des identités
  de service distinctes.
- **La portée du résultat dépend de la configuration déployée.** Les mesures concernent ce banc kind, avec
  kindnet et des flux MCP internes en HTTP. La réapplication des manifestes a été vérifiée. Une mise à jour
  Helm et un retour arrière complet restent à rejouer avant de considérer cette configuration comme durable.
