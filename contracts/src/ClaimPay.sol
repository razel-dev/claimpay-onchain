// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClaimPay — protocole de paiement conditionnel non-custodial
/// @notice Le contrat ne stocke que des engagements (montants, hashes, statuts),
///         jamais de données métier. Tout le reste vit off-chain.
/// @dev    PRINCIPE NON-CUSTODIAL : aucun fonds n'est jamais déposé, séquestré,
///         verrouillé ni mis en réserve. Les transferts se feront en approve /
///         transferFrom direct client -> provider au moment de l'approbation.
///         Anti-patterns proscrits : deposit(), escrow, lock de fonds, provision.
///
///         MACHINES À ÉTATS
///         Accord : DRAFT -> SIGNED -> ACTIVE -> COMPLETED  ↘ CANCELLED
///         Palier : PENDING -> IN_PROGRESS -> SUBMITTED -> APPROVED -> PAID
///                                           ↘ DISPUTED -> RESOLVED -> (PAID | VOID)
///         (SIGNED, APPROVED, RESOLVED sont transitoires : l'écriture finale
///          stockée est respectivement ACTIVE, PAID, et PAID|VOID.)
contract ClaimPay {
    // --------------------------------------------------------------------- //
    //                                 Types                                  //
    // --------------------------------------------------------------------- //

    enum AgreementState {
        DRAFT, // créé, en attente de signature du provider
        SIGNED, // transitoire (la signature mène directement à ACTIVE)
        ACTIVE, // signé, exécution en cours
        COMPLETED, // tous les paliers réglés
        CANCELLED // annulé (expiration côté client)
    }

    enum MilestoneState {
        PENDING, // non démarré
        IN_PROGRESS, // démarré (fonds vérifiés) ou renvoyé en révision
        SUBMITTED, // livrable soumis par le provider
        APPROVED, // transitoire (l'approbation EST le paiement)
        PAID, // réglé (approbation directe ou arbitrage favorable)
        DISPUTED, // litige ouvert
        RESOLVED, // transitoire (l'arbitre a tranché)
        VOID // arbitrage à 0 pour le provider : palier clos sans paiement
    }

    /// @dev `submittedAt == 0` distingue un palier IN_PROGRESS « jamais soumis »
    ///      (démarrage frais) d'un palier IN_PROGRESS « en boucle de révision »
    ///      (déjà soumis au moins une fois). Cf. docs/storage.md.
    struct Milestone {
        uint256 amount;
        MilestoneState state;
        uint64 startedAt;
        uint64 submittedAt;
        bytes32 deliverableHash;
    }

    struct Agreement {
        address client;
        address provider;
        address token;
        uint256 totalAmount;
        AgreementState state;
        uint256 cursor; // index du palier courant ; avance de façon monotone
        bytes32 termsHash;
        address arbiter;
        uint64 createdAt;
        uint64 responseDeadline; // DURÉE (s) ajoutée à createdAt/startedAt/submittedAt
        Milestone[] milestones;
    }

    // --------------------------------------------------------------------- //
    //                                Storage                                //
    // --------------------------------------------------------------------- //

    uint256 public agreementCount;
    mapping(uint256 => Agreement) private _agreements;

    /// @notice Tokens autorisés comme moyen de paiement (USDC en dev/démo).
    mapping(address => bool) public isTokenWhitelisted;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //

    event AgreementCreated(
        uint256 indexed id,
        address indexed client,
        address indexed provider,
        address token,
        address arbiter,
        uint256 totalAmount,
        uint256 milestoneCount
    );
    event AgreementSigned(uint256 indexed id, address indexed provider);
    event MilestoneStarted(uint256 indexed id, uint256 indexed index);
    event MilestoneSubmitted(uint256 indexed id, uint256 indexed index, bytes32 deliverableHash);
    event MilestonePaid(
        uint256 indexed id, uint256 indexed index, address indexed client, address provider, uint256 amount
    );
    event RevisionRequested(uint256 indexed id, uint256 indexed index);
    event DisputeOpened(uint256 indexed id, uint256 indexed index, address indexed opener);
    event DisputeResolved(
        uint256 indexed id, uint256 indexed index, address client, address provider, uint256 amountToProvider
    );
    event AgreementCancelled(uint256 indexed id, address indexed by);
    event TokenWhitelisted(address indexed token, bool allowed);

    // --------------------------------------------------------------------- //
    //                                Errors                                 //
    // --------------------------------------------------------------------- //

    error AgreementDoesNotExist();
    error NotClient();
    error NotProvider();
    error NotArbiter();
    error NotParty();
    error InvalidAgreementState();
    error InvalidMilestoneState();
    error NotCurrentMilestone();
    error TokenNotWhitelisted();
    error ZeroAddress();
    error ProviderIsClient();
    error ArbiterNotNeutral();
    error EmptyMilestones();
    error ZeroMilestoneAmount();
    error ZeroDeadline();
    error DeadlinePassed();
    error DeadlineNotReached();
    error InsufficientAllowance();
    error InsufficientBalance();
    error AmountExceedsMilestone();
    error CannotCancel();
}
