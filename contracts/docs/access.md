# Contrôle d'accès

## Rôle global : `DEFAULT_ADMIN_ROLE` (OpenZeppelin AccessControl)

Une seule responsabilité globale : gérer la whitelist de tokens.

- Accordé au déployeur (ou à l'`admin` passé au constructeur) au déploiement.
- `setTokenWhitelisted(token, allowed)` est `onlyRole(DEFAULT_ADMIN_ROLE)`.
- Un `createAgreement` avec un token non whitelisté → `TokenNotWhitelisted` (Sprint 4).
- La whitelist n'est lue qu'à la création. Retirer un token ensuite n'affecte pas
  les accords déjà créés (le `token` d'un accord est immuable).

## Pas de rôle « arbitre » global

L'arbitre n'est pas un rôle AccessControl : il est fixé par accord, à la création
(Sprint 4), et est immuable. Seul cet arbitre peut appeler `resolveDispute` sur
l'accord concerné.
