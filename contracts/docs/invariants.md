# Invariants & fuzzing

## Tests fuzzés (entrées aléatoires bornées)

- `testFuzz_createAgreement_totalMatchesSum` : pour tout couple de montants > 0,
  le `totalAmount` stocké égale la somme des paliers.
- `testFuzz_resolveDispute_neverPaysMoreThanMilestone` : pour tout montant arbitré
  borné au palier, le provider reçoit exactement ce montant, jamais plus.
- `testFuzz_resolveDispute_revertIfExceeds` : tout montant > palier revert
  (`AmountExceedsMilestone`).

## Invariants (séquences d'appels aléatoires via handler)

Le handler (`test/handlers/ClaimPayHandler.sol`) pilote un accord unique à 3 paliers
et expose six actions sûres (start/submit/revise/approve/dispute/resolve) que Foundry
appelle dans un ordre aléatoire. Après chaque appel, on vérifie :

- `invariant_providerBalanceMatchesPaid` : le solde du provider égale toujours la
  somme effectivement versée (ghost `totalPaid`). Prouve qu'aucun double paiement
  ni fuite n'est possible.
- `invariant_totalPaidNeverExceedsTotal` : la somme versée ne dépasse jamais le
  total de l'accord (3 × 1000 USDC).
- `invariant_cursorBounded` : le curseur reste borné par le nombre de paliers
  (jamais de dépassement, monotonie respectée).

Résultat : 256 runs × 500 calls = 128 000 appels par invariant, 0 revert, 0 discard.

## Propriétés du design couvertes

- Somme des paiements ≤ `totalAmount` : invariant + fuzz resolveDispute.
- Curseur monotone et borné : invariant_cursorBounded.
- Un palier payé ne se repaie pas : garanti par le garde d'état (PAID n'est jamais
  SUBMITTED/DISPUTED) et vérifié par les séquences aléatoires.
- Boucle révision/soumission sans mouvement de fonds : test_revisionLoop + séquences.
- Aucune annulation par expiration si un palier a progressé : test_cancel_revert_ifMilestoneProgressed.
