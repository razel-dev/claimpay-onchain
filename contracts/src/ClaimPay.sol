// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
contract ClaimPay is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
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

    // --------------------------------------------------------------------- //
    //                              Constructor                              //
    // --------------------------------------------------------------------- //

    /// @param admin détenteur de DEFAULT_ADMIN_ROLE (gère la whitelist de tokens).
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin == address(0) ? msg.sender : admin);
    }

    // --------------------------------------------------------------------- //
    //                         Admin : token whitelist                       //
    // --------------------------------------------------------------------- //

    /// @notice Autorise ou retire un token comme moyen de paiement.
    /// @dev Réservé à DEFAULT_ADMIN_ROLE. La whitelist n'est consultée qu'à la
    ///      création d'un accord : un accord déjà créé reste valide même si le
    ///      token est retiré ensuite (immutabilité du token de l'accord).
    function setTokenWhitelisted(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isTokenWhitelisted[token] = allowed;
        emit TokenWhitelisted(token, allowed);
    }

    // --------------------------------------------------------------------- //
    //                         Cycle de vie de l'accord                      //
    // --------------------------------------------------------------------- //

    /// @notice Crée un accord et ses paliers. Aucun fonds n'est déplacé ni bloqué.
    /// @param provider          prestataire (≠ client).
    /// @param token             moyen de paiement (doit être whitelisté).
    /// @param amounts           montants des paliers (chacun > 0, au moins un).
    /// @param termsHash         empreinte des CGU/contrat off-chain (au plus une).
    /// @param arbiter           tiers neutre (≠ client, ≠ provider).
    /// @param responseDeadline  durée de réponse en secondes (> 0).
    /// @return id identifiant de l'accord.
    function createAgreement(
        address provider,
        address token,
        uint256[] calldata amounts,
        bytes32 termsHash,
        address arbiter,
        uint64 responseDeadline
    ) external returns (uint256 id) {
        if (!isTokenWhitelisted[token]) revert TokenNotWhitelisted();
        if (provider == address(0) || arbiter == address(0)) revert ZeroAddress();
        if (provider == msg.sender) revert ProviderIsClient();
        if (arbiter == msg.sender || arbiter == provider) revert ArbiterNotNeutral();
        uint256 n = amounts.length;
        if (n == 0) revert EmptyMilestones();
        if (responseDeadline == 0) revert ZeroDeadline();

        id = agreementCount++;
        Agreement storage a = _agreements[id];
        a.client = msg.sender;
        a.provider = provider;
        a.token = token;
        a.arbiter = arbiter;
        a.termsHash = termsHash;
        a.state = AgreementState.DRAFT;
        a.createdAt = uint64(block.timestamp);
        a.responseDeadline = responseDeadline;

        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 amt = amounts[i];
            if (amt == 0) revert ZeroMilestoneAmount();
            total += amt;
            a.milestones
                .push(
                    Milestone({
                        amount: amt,
                        state: MilestoneState.PENDING,
                        startedAt: 0,
                        submittedAt: 0,
                        deliverableHash: bytes32(0)
                    })
                );
        }
        a.totalAmount = total; // invariant: somme(amounts) == totalAmount, par construction

        emit AgreementCreated(id, msg.sender, provider, token, arbiter, total, n);
    }

    /// @notice Le provider accepte l'accord : DRAFT -> SIGNED -> ACTIVE.
    /// @dev Signature impossible après expiration (createdAt + responseDeadline) : US-12.
    function signAgreement(uint256 id) external {
        Agreement storage a = _get(id);
        if (msg.sender != a.provider) revert NotProvider();
        if (a.state != AgreementState.DRAFT) revert InvalidAgreementState();
        // Deadline « grosses mailles » (heures/jours) : la marge de manipulation
        // de block.timestamp par un validateur (~secondes) est négligeable ici.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > uint256(a.createdAt) + uint256(a.responseDeadline)) revert DeadlinePassed();
        a.state = AgreementState.ACTIVE;
        emit AgreementSigned(id, msg.sender);
    }

    // --------------------------------------------------------------------- //
    //                          Cycle de vie du palier                       //
    // --------------------------------------------------------------------- //

    /// @notice Le client démarre le palier courant : vérification de solvabilité
    ///         front-loadée, SANS custody. PENDING -> IN_PROGRESS.
    /// @dev C'est le CLIENT qui démarre : il engage sa volonté de payer, et la
    ///      vérification porte sur SON allowance/balance. Le provider doit ensuite
    ///      soumettre ; à défaut, US-13 (provider fantôme, Sprint 10).
    function startMilestone(uint256 id, uint256 index) external {
        Agreement storage a = _get(id);
        if (msg.sender != a.client) revert NotClient();
        if (a.state != AgreementState.ACTIVE) revert InvalidAgreementState();
        if (index != a.cursor) revert NotCurrentMilestone();
        Milestone storage m = a.milestones[index];
        if (m.state != MilestoneState.PENDING) revert InvalidMilestoneState();

        IERC20 t = IERC20(a.token);
        if (t.allowance(a.client, address(this)) < m.amount) revert InsufficientAllowance();
        if (t.balanceOf(a.client) < m.amount) revert InsufficientBalance();

        m.startedAt = uint64(block.timestamp);
        m.state = MilestoneState.IN_PROGRESS;
        emit MilestoneStarted(id, index);
    }

    /// @notice Le provider soumet le livrable (empreinte 32 octets). IN_PROGRESS -> SUBMITTED.
    /// @dev Réutilisable après une révision : écrase deliverableHash et submittedAt.
    function submitMilestone(uint256 id, uint256 index, bytes32 deliverableHash) external {
        Agreement storage a = _get(id);
        if (msg.sender != a.provider) revert NotProvider();
        Milestone storage m = a.milestones[index];
        if (m.state != MilestoneState.IN_PROGRESS) revert InvalidMilestoneState();

        m.deliverableHash = deliverableHash;
        m.submittedAt = uint64(block.timestamp);
        m.state = MilestoneState.SUBMITTED;
        emit MilestoneSubmitted(id, index, deliverableHash);
    }

    /// @notice L'approbation EST le paiement, atomique. SUBMITTED -> PAID.
    /// @dev Pattern Checks-Effects-Interactions + nonReentrant. Si l'allowance ou le
    ///      solde du client est insuffisant au moment du transfert, toute la
    ///      transaction revert (rollback global) : aucun état n'est avancé.
    function approveMilestone(uint256 id, uint256 index) external nonReentrant {
        Agreement storage a = _get(id);
        if (msg.sender != a.client) revert NotClient();
        if (index != a.cursor) revert NotCurrentMilestone();
        Milestone storage m = a.milestones[index];
        if (m.state != MilestoneState.SUBMITTED) revert InvalidMilestoneState();

        uint256 amount = m.amount;

        // ---- Effects ----
        m.state = MilestoneState.PAID;
        a.cursor = index + 1;
        if (a.cursor == a.milestones.length) a.state = AgreementState.COMPLETED;

        // ---- Interaction ----
        IERC20(a.token).safeTransferFrom(a.client, a.provider, amount);

        emit MilestonePaid(id, index, a.client, a.provider, amount);
    }

    /// @notice Le client demande une révision : aller-retour collaboratif, sans
    ///         conséquence sur les fonds. SUBMITTED -> IN_PROGRESS. Appelable en boucle.
    /// @dev Distinct du litige : aucun mouvement de fonds, cursor inchangé. Le
    ///      compteur de révisions et tout seuil/nudge vivent côté app.
    ///      submittedAt est conservé : il marque qu'on est en boucle de révision.
    function requestRevision(uint256 id, uint256 index) external {
        Agreement storage a = _get(id);
        if (msg.sender != a.client) revert NotClient();
        Milestone storage m = a.milestones[index];
        if (m.state != MilestoneState.SUBMITTED) revert InvalidMilestoneState();

        m.state = MilestoneState.IN_PROGRESS;
        emit RevisionRequested(id, index);
    }

    // --------------------------------------------------------------------- //
    //                                Litiges                                //
    // --------------------------------------------------------------------- //

    /// @notice Ouvre un litige sur le palier courant. -> DISPUTED.
    /// @dev Réutilise createdAt/startedAt/submittedAt — aucun nouveau champ.
    ///      Quatre voies (toutes pinées sur cursor par le garde d'état) :
    ///       (A) SUBMITTED + client          : rejet du livrable, à tout moment.
    ///       (US-14) SUBMITTED + provider     : client fantôme, après submittedAt + délai.
    ///       (US-13) IN_PROGRESS + client     : provider fantôme (submittedAt == 0),
    ///                                          après startedAt + délai.
    ///       (boucle) IN_PROGRESS + provider  : sortie de boucle de révision
    ///                                          (submittedAt != 0), après submittedAt + délai.
    ///      Avant l'échéance, les voies à timeout revert (DeadlineNotReached).
    function openDispute(uint256 id, uint256 index) external {
        Agreement storage a = _get(id);
        if (a.state != AgreementState.ACTIVE) revert InvalidAgreementState();
        if (index != a.cursor) revert NotCurrentMilestone();
        Milestone storage m = a.milestones[index];

        if (m.state == MilestoneState.SUBMITTED) {
            if (msg.sender == a.client) {
                // (A) rejet du livrable — à tout moment.
            } else if (msg.sender == a.provider) {
                // (US-14) client fantôme — fenêtre depuis la soumission.
                // forge-lint: disable-next-line(block-timestamp)
                if (block.timestamp <= uint256(m.submittedAt) + uint256(a.responseDeadline)) {
                    revert DeadlineNotReached();
                }
            } else {
                revert NotParty();
            }
        } else if (m.state == MilestoneState.IN_PROGRESS) {
            if (m.submittedAt == 0) {
                // (US-13) démarrage frais, jamais soumis — le client ouvre après timeout.
                if (msg.sender != a.client) revert NotParty();
                // forge-lint: disable-next-line(block-timestamp)
                if (block.timestamp <= uint256(m.startedAt) + uint256(a.responseDeadline)) {
                    revert DeadlineNotReached();
                }
            } else {
                // (boucle) le provider sort d'une boucle de révision après timeout.
                if (msg.sender != a.provider) revert NotParty();
                // forge-lint: disable-next-line(block-timestamp)
                if (block.timestamp <= uint256(m.submittedAt) + uint256(a.responseDeadline)) {
                    revert DeadlineNotReached();
                }
            }
        } else {
            revert InvalidMilestoneState();
        }

        m.state = MilestoneState.DISPUTED;
        emit DisputeOpened(id, index, msg.sender);
    }

    /// @notice L'arbitre tranche : l'issue déplace (ou non) les fonds. -> PAID | VOID.
    /// @param amountToProvider montant accordé au provider (≤ amount du palier).
    ///        Le reliquat (amount - amountToProvider) n'est jamais transféré : il
    ///        reste simplement chez le client (rien n'était séquestré).
    /// @dev CEI + nonReentrant. amountToProvider == 0 => VOID (aucun transfert).
    function resolveDispute(uint256 id, uint256 index, uint256 amountToProvider) external nonReentrant {
        Agreement storage a = _get(id);
        if (msg.sender != a.arbiter) revert NotArbiter();
        if (index != a.cursor) revert NotCurrentMilestone();
        Milestone storage m = a.milestones[index];
        if (m.state != MilestoneState.DISPUTED) revert InvalidMilestoneState();
        if (amountToProvider > m.amount) revert AmountExceedsMilestone();

        // ---- Effects ----
        m.state = amountToProvider > 0 ? MilestoneState.PAID : MilestoneState.VOID;
        a.cursor = index + 1;
        if (a.cursor == a.milestones.length) a.state = AgreementState.COMPLETED;

        // ---- Interaction ----
        if (amountToProvider > 0) {
            IERC20(a.token).safeTransferFrom(a.client, a.provider, amountToProvider);
        }

        emit DisputeResolved(id, index, a.client, a.provider, amountToProvider);
    }

    // --------------------------------------------------------------------- //
    //                                Internal                               //
    // --------------------------------------------------------------------- //

    function _get(uint256 id) private view returns (Agreement storage a) {
        if (id >= agreementCount) revert AgreementDoesNotExist();
        a = _agreements[id];
    }
}
