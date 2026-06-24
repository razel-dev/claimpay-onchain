# Layout de stockage

## `Agreement`

| Champ              | Type              | Écrit par             | Rôle |
|--------------------|-------------------|-----------------------|------|
| `client`           | `address`         | `createAgreement`     | partie immuable, paie |
| `provider`         | `address`         | `createAgreement`     | partie immuable, reçoit |
| `token`            | `address`         | `createAgreement`     | moyen de paiement (whitelisté à la création) |
| `totalAmount`      | `uint256`         | `createAgreement`     | somme des paliers (dérivée, par construction) |
| `state`            | `AgreementState`  | sign/approve/...      | DRAFT→ACTIVE→COMPLETED ↘ CANCELLED |
| `cursor`           | `uint256`         | approve/resolve       | index du palier courant, **monotone croissant** |
| `termsHash`        | `bytes32`         | `createAgreement`     | au plus un engagement de termes off-chain |
| `arbiter`          | `address`         | `createAgreement`     | tiers neutre immuable |
| `createdAt`        | `uint64`          | `createAgreement`     | base des échéances d'expiration |
| `responseDeadline` | `uint64`          | `createAgreement`     | **durée** (s) ajoutée à createdAt/startedAt/submittedAt |
| `milestones`       | `Milestone[]`     | `createAgreement`     | paliers |

## `Milestone`

| Champ             | Type             | Écrit par           | Rôle |
|-------------------|------------------|---------------------|------|
| `amount`          | `uint256`        | `createAgreement`   | montant du palier (> 0) |
| `state`           | `MilestoneState` | start/submit/...    | PENDING→IN_PROGRESS→SUBMITTED→PAID ↘ DISPUTED→(PAID\|VOID) |
| `startedAt`       | `uint64`         | `startMilestone`    | écrit une seule fois |
| `submittedAt`     | `uint64`         | `submitMilestone`   | écrit à chaque soumission (écrasé en boucle de révision) |
| `deliverableHash` | `bytes32`        | `submitMilestone`   | empreinte du livrable courant |

## Pourquoi deux timestamps en plus de `submittedAt`

On veut minimiser les champs, mais `submittedAt` seul ne couvre qu'un cas : « palier
soumis sans réponse ». Il manque :

- **« accord jamais signé / jamais démarré »** → couvert par `createdAt` (Agreement).
- **« palier démarré mais jamais soumis »** (provider fantôme, US-13) → couvert par `startedAt` (Milestone).

Ces deux timestamps sont écrits une seule fois chacun et servent uniquement de base
aux échéances d'expiration. Aucun nouveau champ n'est introduit pour les litiges :
les fonctions à venir réutilisent `createdAt`, `startedAt`, `submittedAt`.

## Invariant `submittedAt` (marqueur de boucle de révision)

Un palier `IN_PROGRESS` peut être dans deux situations distinguées par `submittedAt` :

- `submittedAt == 0` → **démarrage frais**, jamais soumis. Timeout depuis `startedAt`.
- `submittedAt != 0` → **boucle de révision** (déjà soumis, renvoyé). Timeout depuis `submittedAt`.

## Invariant « un seul palier actif à la fois »

Seul `milestones[cursor]` peut être dans un état actif
(`IN_PROGRESS`/`SUBMITTED`/`DISPUTED`). Les paliers d'index `< cursor` sont réglés
(`PAID`/`VOID`), ceux d'index `> cursor` sont `PENDING`.