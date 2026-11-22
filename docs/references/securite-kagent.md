# Sécurité de kagent sur le banc : test d'intrusion et durcissement

Ce document décrit un risque de sécurité **constaté** sur une installation de kagent 1.0.1 par défaut (voie CLI),
le **test rejouable** qui le prouve, et les **mesures de durcissement** pour le traiter.

> Cadre : banc d'essai jetable, cluster kind `kagent`, aucun secret réel, aucun environnement de production.
> But : sensibiliser aux risques d'un serveur d'outils d'agent IA, et montrer de bonnes pratiques. Comparé au banc OpenCode.

Les termes (RBAC, compte de service, MCP, NetworkPolicy...) sont définis dans `termes.md` (dépôt privé).

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

### Les couches de contrôle (et lesquelles manquent)

Protéger un serveur d'outils ne se résume pas à une barrière. Il y a plusieurs couches, indépendantes, et il faut
savoir ce que chacune sait faire. Le filtrage réseau, par exemple, garde la porte mais ne dit pas qui entre.

| Couche | Question | Mécanisme | État par défaut | Après durcissement |
|--------|----------|-----------|-----------------|--------------------|
| 1. Atteignabilité réseau | qui peut **joindre** le port 8084 ? | NetworkPolicy | aucune (tout le cluster) | `kagent` + passerelle `atenet-egress` seulement |
| 2. Authentification | **qui** appelle ? | identité applicative (jeton, mTLS/SPIFFE) | **aucune** (un pod intrus obtient `initialize` 200) | inchangé (pas d'auth sur le serveur) |
| 3. Autorisation de l'appel | **quoi** : quels outils, quels namespaces ? | liste d'outils par agent (`mcp.tools`), `requireApproval` | définie par agent, mais **contournée** par un appel MCP direct (ne vaut que sur le chemin agent → outil) | inchangé (contournable) |
| 4. Privilège réel d'exécution | que peut faire le serveur sur le cluster ? | RBAC du compte de service de `kagent-tools` | **administrateur du cluster** | **lecture seule, sans Secrets** |
| 5. Sortie du bac à sable | que peut joindre l'agent ? | egress policy du Substrate | passerelle imposée | inchangé |
| 6. Traçabilité | qu'a fait l'agent ? | interface web, OpenTelemetry | disponible | inchangé |

2 enseignements :
- **La couche réseau (1) garde la porte, elle ne connaît pas l'appelant.** Tous les agents arrivent par la passerelle,
  donc une NetworkPolicy ne peut pas distinguer un agent d'un autre ni savoir « quel agent » : cela relève de la
  couche 2 (authentification), absente par défaut.
- **Les garde-fous « par agent » (couche 3) ne sont pas une barrière de sécurité.** Liste d'outils et validation
  humaine ne s'appliquent qu'au chemin agent → outil ; un appel direct au serveur les ignore. La seule limite qui tient
  contre un appelant quelconque est le **privilège réel d'exécution (couche 4), le RBAC** : c'est lui qui plafonne les
  dégâts, quel que soit celui qui appelle. C'est pourquoi le durcissement agit d'abord sur la couche 4, puis sur la 1.

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
export KUBECONFIG=~/kagent-lab/kubeconfig
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

Fichiers : [hardening/rbac.yaml](../../kagent/hardening/rbac.yaml), [hardening/networkpolicy.yaml](../../kagent/hardening/networkpolicy.yaml).
Sauvegarde de l'état d'origine avant modification : `~/kagent-lab/avant-durcissement/` (sur l'instance).

```bash
export KUBECONFIG=~/kagent-lab/kubeconfig
kubectl137 apply -f kagent/hardening/rbac.yaml
kubectl137 apply -f kagent/hardening/networkpolicy.yaml
./kagent/test-intrusion.sh ; echo "code=$?"   # attendu : 0
```

### Résultats mesurés (2026-11-21)

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

Le flux authentifié passe par deux instances distinctes d’AgentGateway. `atenet-egress` est la passerelle de sortie de Substrate. `kagent-mcp-auth` vérifie les jetons devant `kagent-tools`. Les schémas et mesures précédents décrivent le banc avant cette bascule.

```text
Agents diag-lecture et diag-lecture-gpt41
  │ Appel MCP vers le RemoteMCPServer configuré avec actorJwt
  ▼
atenet-egress (AgentGateway existant, namespace ate-system)
  │ Injecte Authorization: Bearer <Actor JWT> pour l’audience du serveur MCP
  ▼
Proxy MCP interne (seconde instance d’AgentGateway)
  │ Valide le JWT avec les clés publiques de l’IdP Substrate (JWKS sur HTTPS)
  │ Transmet uniquement les requêtes authentifiées
  ▼
kagent-tools:8084
  │ Appelle Kubernetes avec le compte de service kagent-tools
  ▼
API Kubernetes du cluster kagent (RBAC en lecture seule)
```

- **Émission et injection.** Le `RemoteMCPServer` pointe vers le proxy et demande un jeton pour une audience dédiée, par exemple `kagent-tools-mcp`. Substrate émet le jeton de l’Actor d’exécution et `atenet-egress` l’ajoute à la requête MCP.
- **Validation à l’entrée.** Le proxy vérifie la signature, l’émetteur, l’audience et l’expiration, avec la CA interne pour joindre l’IdP. Il refuse les requêtes sans jeton valide. La politique réseau réserve l’accès à `kagent-tools:8084` aux pods de ce proxy.
- **Autorisation Kubernetes.** Le compte de service `kagent-tools` et son RBAC contrôlent les lectures auprès de l’API Kubernetes. Le JWT de l’Actor sert à authentifier l’appel MCP. Une restriction aux deux agents nommés demanderait également une politique d’autorisation fondée sur leur identité.

Sur le banc, Agent Substrate fournit déjà un IdP interne dans `ate-system`. Le proxy utilise le bundle de
confiance Kubernetes des certificats DNS de Substrate pour récupérer son JWKS sur HTTPS. Les appels MCP
internes du banc restent sur HTTP. Les ressources à déployer et les tests de reprise sont dans le
[répertoire ActorJWT](../../kagent/hardening/actorjwt/).

[Injection ActorJWT dans kagent](https://github.com/kagent-dev/kagent/pull/3359) · [Vérification des jetons Substrate](https://ate.dev/docs/guides/actor-jwts/)

## 5. À retenir (pour l'article)

- Un serveur d'outils d'agent est un **point de concentration de privilèges** : ses droits comptent plus que ceux de l'agent.
- Les garde-fous « côté agent » (liste d'outils, validation humaine) ne remplacent pas le RBAC et le filtrage réseau.
- Le modèle « agent dans le cluster » rapproche l'outil des ressources sensibles : l'isolation réseau devient essentielle.
- À comparer au modèle « agent conteneurisé sur le poste » (OpenCode) : `GUIDE.md` (dépôt privé), étape 10 bis.
