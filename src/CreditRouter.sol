// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice ScoreToken: wraps Credits to SCORE. `wrap` pulls the Credits from its caller (this router) via
/// transferFrom, so the router must hold them and have approved SCORE as an operator on the Credits collection.
/// `wrapOpen` reports whether wrapping is open to everyone (not paused, no migration, no emergency exit).
interface IScoreWrap {
    function wrap(uint256[] calldata ids, address to) external returns (uint256 amount);
    function wrapOpen() external view returns (bool);
}

/// @notice The SCORE/ETH pool. The router reads the dev fee, the dev wallet, the owner and whether it has launched
/// live, so a lowered dev fee, a changed dev wallet or a new owner is honoured without redeploying.
interface IScorePool {
    function hook() external view returns (IHooks);
    function devWallet() external view returns (address);
    function devFeeBps() external view returns (uint256);
    function launched() external view returns (bool);
    function owner() external view returns (address);
}

/// @notice The SCORE pool hook (PoolHookBase): its Burner and Builder are the protocol's two fee sinks, set once on
/// the hook and never changed, so the router caches them.
interface IHook {
    function burner() external view returns (address);
    function builder() external view returns (address);
}

/// @notice The Credits ERC-721 collection (0x9763…). Transfers are unrestricted (the venue gate guards only SCORE).
interface ICredits {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function setApprovalForAll(address operator, bool approved) external;
}

/// @notice The standard Uniswap Universal Router (no custom swap router). Only the entry point the router uses.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

// --- Seaport 1.6 order types (0x0000000000000068F116a894984e2DB1123eB395), the subset the router decodes ---

enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    uint8 orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

enum Side {
    OFFER,
    CONSIDERATION
}

/// @notice A criteria resolver names the concrete token id that satisfies a criteria (collection/trait) offer or
/// consideration item. Credits listings name a concrete token id, so the router passes an empty resolver array.
struct CriteriaResolver {
    uint256 orderIndex;
    Side side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

/// @notice A Seaport advanced order: an order plus the fraction to fill (`numerator`/`denominator`) and the zone's
/// off-chain `extraData`. For a full (non-partial) fill numerator == denominator == 1. For a RESTRICTED order
/// (OpenSea listings) `extraData` is the payload fetched from OpenSea's `/listings/fulfillment_data` endpoint and
/// handed to the order's zone; for an open order it is empty.
struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

/// @notice One item of one order, by position, for the fulfillment arrays of `fulfillAvailableAdvancedOrders`.
struct FulfillmentComponent {
    uint256 orderIndex;
    uint256 itemIndex;
}

struct ReceivedItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
    address payable recipient;
}

struct Execution {
    ReceivedItem item;
    address offerer;
    bytes32 conduitKey;
}

interface ISeaport {
    /// @notice Fulfils as many of `advancedOrders` as can be filled now, skipping any that are not yet started,
    /// expired, cancelled or already filled (an order's status and time), or whose restricted zone declines it up
    /// front (`authorizeOrder`). An order whose offerer no longer holds or approves the item is not skipped: its
    /// transfer fails and reverts the whole batch. Unlike `fulfillAvailableOrders`, this path
    /// can execute RESTRICTED orders: each fulfilled restricted order's zone is called with the order's `extraData`
    /// and must approve, so live OpenSea listings (which carry an OpenSea zone) can be filled. `availableOrders[i]`
    /// reports whether order `i` executed. `criteriaResolvers` resolves collection/trait (criteria) items and is
    /// empty here, as Credits listings name a concrete token id. Each offer and consideration item is listed in its
    /// own singleton fulfillment group (no aggregation across orders), so independent listings stay independent. The
    /// offered items go to `recipient`; unused native ETH is refunded to the caller.
    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] calldata advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    ) external payable returns (bool[] memory availableOrders, Execution[] memory executions);
}

/// @title CreditRouter
/// @notice Site periphery that bridges Credits and the SCORE/ETH pool in one transaction. It does not hold funds
/// between calls and runs no swap logic of its own: it calls the standard Universal Router for the SCORE/ETH swap
/// and the canonical Seaport for the Credits purchase.
///  - `sellCreditsForEth`: pull the caller's Credits, wrap them to SCORE, sell the SCORE for ETH through the real
///    Universal Router, and forward the ETH to `to`. No fee of the router's own; the pool's own 1% swap fee is the
///    only cut. Only from launch on (the pool opens at launch) and while wrapping is open.
///  - `buyCreditsWithEth`: fulfil a supplied BATCH of Seaport listings for Credit(s) with the caller's ETH via
///    `fulfillAvailableAdvancedOrders` (partial fills: listings Seaport reports unavailable are skipped) and refund
///    the unused ETH. It runs in one of three modes:
///    - before launch (when only the pool may wrap): the Credits themselves go to `to`, and 0.5% of the price of the
///      listings filled is paid to the pool's owner;
///    - from launch on, while wrapping is open (`IScoreWrap.wrapOpen`): the Credits are wrapped to SCORE for `to`,
///      and 1% of that price is routed like the protocol's fees (dev wallet, Burner, Builder);
///    - from launch on, while wrapping is closed (paused, migrating or the emergency exit open): the Credits
///      themselves go to `to`, with the same routed 1%.
///    Advanced orders carry per-order `extraData`, so LIVE OpenSea listings (RESTRICTED orders behind an OpenSea
///    zone) can be filled as well as self-validated / open orders. CONTRACT orders are refused.
///
/// @dev Wiring the deployer must add in production (mirrored in the tests via the guard):
///  - Allow this router to RECEIVE SCORE on the SCORE venue gate (ScoreGuard.setAllowed): the sell path wraps to
///    the router, which mints SCORE to a contract, so the receiver allowlist must admit it. The buy path wraps
///    straight to `to`, so it needs no allowance for the router itself.
///  - This router does not need the POOL gate: it never receives POOL.
/// @custom:disclaimer Experimental software, not audited by an independent security firm. You may lose everything
/// you commit.
contract CreditRouter is ReentrancyGuard {
    /// @notice Standard Uniswap Universal Router (mainnet).
    address public constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    /// @notice Permit2 (mainnet).
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @notice Canonical Seaport 1.6 (mainnet).
    address public constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    /// @notice The Universal Router command byte for a v4 swap (Commands.V4_SWAP).
    bytes1 private constant V4_SWAP = 0x10;
    uint256 private constant BPS = 10_000;
    int24 private constant TICK_SPACING = 200;
    /// @notice The router's fee on a buy from launch on (wrapped or not), in bps of the ETH paid to the listings.
    uint256 public constant FEE_BPS = 100; // 1%
    /// @notice The router's fee on a buy before launch (the Credits are delivered as they are), to the pool's owner.
    uint256 public constant PRELAUNCH_FEE_BPS = 50; // 0.5%

    IScoreWrap public immutable score;
    ICredits public immutable credits;
    IScorePool public immutable pool;
    /// @notice The protocol's two ETH fee sinks, read once off the pool's hook: the Burner (buyback + burn) and the
    /// Builder (protocol-owned liquidity).
    address public immutable burner;
    address public immutable builder;
    /// @notice The SCORE/ETH pool key: currency0 = ETH, currency1 = SCORE, dynamic fee, tick spacing 200.
    PoolKey public poolKey;
    /// @notice Dev fees a reverting dev wallet could not take, held in the router and retried on the next routed fee or
    /// by `flushDevFee`. Non-zero only while the dev wallet is rejecting ETH; the Burner/Builder split is never
    /// affected.
    uint256 public devWalletOwed;
    /// @notice Pre-launch fees the pool's owner could not take, held in the router and retried on the next pre-launch
    /// fee or by `flushOwnerFee`.
    uint256 public ownerOwed;

    event SoldCreditsForEth(address indexed from, address indexed to, uint256 scoreWrapped, uint256 ethOut);
    event BoughtCreditsWithEth(
        address indexed buyer,
        address indexed to,
        uint256 filled,
        uint256 ethSpent,
        uint256 fee,
        uint256 scoreOut,
        uint256 refund
    );

    error EmptyIds();
    error BadAddress();
    error NothingWrapped();
    error AmountTooLarge();
    error EthShortfall();
    error OverMax();
    error BadOrder();
    error SendFailed();
    error NotLaunched();
    error WrapClosed();
    error UnsupportedOrderType();

    constructor(IScoreWrap score_, ICredits credits_, IScorePool pool_) {
        if (address(score_) == address(0) || address(credits_) == address(0) || address(pool_) == address(0)) {
            revert BadAddress();
        }
        score = score_;
        credits = credits_;
        pool = pool_;
        IHooks hook = pool_.hook();
        address b = IHook(address(hook)).burner();
        address c = IHook(address(hook)).builder();
        if (b == address(0) || c == address(0)) revert BadAddress();
        burner = b;
        builder = c;
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(score_)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
        // SCORE pulls the Credits from this router during wrap; this is an operator approval on the collection,
        // not a token transfer, so the venue gate is not involved.
        credits_.setApprovalForAll(address(score_), true);
        // Allow Permit2 to pull SCORE for the sell-path swap (an ERC-20 allowance, no balance moves here).
        IERC20(address(score_)).approve(PERMIT2, type(uint256).max);
    }

    /// @notice Accepts ETH from the Universal Router's swap output and from Seaport's native refunds.
    receive() external payable {}

    // --- sell: Credits -> SCORE -> ETH ---

    /// @notice Pulls the caller's Credits (the caller must approve this router on the collection), wraps them to
    /// SCORE held here, sells the SCORE for ETH through the real Universal Router, requires the ETH out to be at
    /// least `minEthOut`, and forwards it to `to`. Atomic: a shortfall reverts the whole call. Reverts with
    /// `NotLaunched` before launch and `WrapClosed` while wrapping is closed.
    /// @dev The router must be an allowed SCORE receiver (see the contract notice), because wrap mints SCORE to it.
    /// @return ethOut ETH forwarded to `to`.
    function sellCreditsForEth(uint256[] calldata creditIds, uint256 minEthOut, address to)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (creditIds.length == 0) revert EmptyIds();
        if (to == address(0)) revert BadAddress();
        if (!pool.launched()) revert NotLaunched(); // SCORE is sold into the pool, which opens at launch
        if (!score.wrapOpen()) revert WrapClosed(); // paused, migrating or the emergency exit open

        for (uint256 i; i < creditIds.length; ++i) {
            credits.transferFrom(msg.sender, address(this), creditIds[i]);
        }
        uint256 amount = score.wrap(creditIds, address(this));
        if (amount == 0) revert NothingWrapped();
        if (amount > type(uint128).max) revert AmountTooLarge();

        uint256 ethBefore = address(this).balance;
        _urSellScoreForEth(uint128(amount));
        ethOut = address(this).balance - ethBefore;
        if (ethOut < minEthOut) revert EthShortfall();

        _sendEth(to, ethOut);
        emit SoldCreditsForEth(msg.sender, to, amount, ethOut);
    }

    /// @dev One real Universal Router exact-in single swap of `amountIn` SCORE (currency1) for ETH (currency0):
    /// V4_SWAP = [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]. SETTLE_ALL pays SCORE via Permit2; TAKE_ALL sends the
    /// ETH to this router (the caller of execute). amountOutMinimum is 0 here; the real floor is enforced on the ETH
    /// actually received, which the router measures itself.
    function _urSellScoreForEth(uint128 amountIn) private {
        PoolKey memory key = poolKey;
        IAllowanceTransfer(PERMIT2).approve(
            Currency.unwrap(key.currency1), UNIVERSAL_ROUTER, amountIn, uint48(block.timestamp)
        );

        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false, // SCORE (currency1) in, ETH (currency0) out
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency1, uint256(amountIn)); // SETTLE_ALL (currency, maxAmount)
        params[2] = abi.encode(key.currency0, uint256(0)); // TAKE_ALL (currency, minAmount)

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp);
    }

    // --- buy: ETH -> Credits (Seaport, bulk + partial fills) -> SCORE ---

    /// @notice Fulfils a supplied batch of Seaport listings for Credit(s) with the caller's ETH, using Seaport's
    /// `fulfillAvailableAdvancedOrders`: listings Seaport reports unavailable (cancelled, expired, not yet started,
    /// already filled, or declined up front by their zone) are skipped and the rest execute. A listing whose Credit
    /// the seller has moved or no longer approves is not skipped: its transfer fails and the whole call reverts, so
    /// the finder must leave it out. Because it is the ADVANCED path, RESTRICTED listings behind a zone (live
    /// OpenSea listings) can be filled too: each listing carries the zone's off-chain `extraData`, which Seaport
    /// forwards to the zone for approval. Before launch (when only the pool may wrap) the Credits themselves go to
    /// `to` and a 0.5% fee goes to the pool's owner. From launch on the fee is 1%, routed like the protocol's fees;
    /// the Credits are wrapped to SCORE for `to` while wrapping is open, and delivered as they are while it is
    /// closed (paused, migrating or the emergency exit open). The fee is charged on the price of the listings filled
    /// (not the attempted total); the rest of the ETH is refunded.
    /// @dev The off-chain order finder supplies the listings; the router only fulfils what it is given. A listing
    /// whose offer is not a concrete Credits ERC-721, whose consideration is not fixed native ETH, or that is not a
    /// full fill (numerator == denominator == 1), is dropped before the batch (not sent to Seaport) rather than
    /// reverting the whole call. A listing that is not FULL_OPEN or FULL_RESTRICTED (orderType 0 or 2) reverts it with
    /// `UnsupportedOrderType`: a CONTRACT order's offerer can return less than the declared consideration, which would
    /// leave ETH on the router, and a PARTIAL order can be filled for less than the whole listing. N = 1 is the ordinary single buy. The caller must fund `msg.value` for the
    /// attempted total plus the worst-case (all fill) fee; whatever is not spent comes back. A restricted listing
    /// whose zone rejects the fill reverts the whole call (Seaport checks every fulfilled order's zone AFTER the
    /// transfers), so such a listing must be excluded by the finder rather than relied on to skip.
    /// @param orders Each entry is abi.encode(AdvancedOrder), where
    ///   AdvancedOrder = { OrderParameters parameters; uint120 numerator; uint120 denominator; bytes signature;
    ///   bytes extraData; }. numerator == denominator == 1 for a full fill; `extraData` is the OpenSea
    ///   `/listings/fulfillment_data` payload for a restricted listing and empty for an open one; `signature` is the
    ///   listing's signature (empty if validated on-chain).
    /// @param maxEthIn The most the caller will actually pay, spent + fee inclusive (checked on the real outcome).
    /// @param to Recipient of the wrapped SCORE (while wrapping is open) or of the Credits (otherwise).
    /// @return scoreOut SCORE delivered to `to` (0 when the Credits are delivered as they are).
    function buyCreditsWithEth(bytes[] calldata orders, uint256 maxEthIn, address to)
        external
        payable
        nonReentrant
        returns (uint256 scoreOut)
    {
        if (to == address(0)) revert BadAddress();
        if (orders.length == 0) revert BadOrder();
        (AdvancedOrder[] memory good, uint256[] memory prices, uint256 attemptedTotal) = _goodOrders(orders);
        if (good.length == 0) {
            // nothing fulfillable: hand the whole payment straight back
            if (msg.value != 0) _sendEth(msg.sender, msg.value);
            return 0;
        }

        // Fund the attempted total plus the worst-case (all fill) fee, so the refund never underflows; the excess
        // (skipped orders' price and fee) is refunded below.
        bool live = pool.launched();
        bool wrapping = live && score.wrapOpen();
        uint256 feeBps = live ? FEE_BPS : PRELAUNCH_FEE_BPS;
        if (msg.value < attemptedTotal + attemptedTotal * feeBps / BPS) revert EthShortfall();

        (bool[] memory available, uint256 actualSpent) =
            _fill(good, prices, attemptedTotal, wrapping ? address(this) : to);
        uint256 fee = actualSpent * feeBps / BPS;
        if (actualSpent + fee > maxEthIn) revert OverMax(); // cap on the real cost; reverts (and undoes Seaport) if over

        uint256[] memory ids = _boughtIds(good, available);
        if (wrapping && ids.length != 0) {
            scoreOut = score.wrap(ids, to); // the router owns the bought Credits; wrap straight to `to`
            if (scoreOut == 0) revert NothingWrapped();
        }
        if (live) {
            _routeFee(fee);
        } else {
            _payOwner(fee);
        }
        uint256 refund = msg.value - actualSpent - fee;
        if (refund != 0) _sendEth(msg.sender, refund);
        emit BoughtCreditsWithEth(msg.sender, to, ids.length, actualSpent, fee, scoreOut, refund);
    }

    /// @dev Decodes and validates the listings, keeping only those the router will fulfil, with each one's price.
    function _goodOrders(bytes[] calldata orders)
        private
        view
        returns (AdvancedOrder[] memory good, uint256[] memory prices, uint256 attemptedTotal)
    {
        good = new AdvancedOrder[](orders.length); // over-allocated, then shrunk to the good listings
        prices = new uint256[](orders.length);
        uint256 g;
        for (uint256 i; i < orders.length; ++i) {
            AdvancedOrder memory o = abi.decode(orders[i], (AdvancedOrder));
            // only a full fill of a concrete ERC-721 listing; a partial-fill fraction is dropped (an ERC-721 cannot
            // be split, and the price model below assumes the whole consideration is paid).
            if (o.numerator != 1 || o.denominator != 1) continue;
            (bool ok, uint256 price) = _checkOrder(o.parameters);
            if (!ok) continue; // a bad listing is skipped, not a batch-wide revert
            good[g] = o;
            prices[g] = price;
            attemptedTotal += price;
            unchecked {
                ++g;
            }
        }
        assembly ("memory-safe") {
            mstore(good, g)
            mstore(prices, g)
        }
    }

    /// @dev Fills the listings through Seaport, delivering the Credits to `recipient`. Seaport takes only what the
    /// fills cost and refunds the rest to this router. The ETH spent is the price of the listings Seaport filled, as
    /// validated, never the balance difference: ETH a payee sends back to this router during the fill neither lowers
    /// the fee nor reaches the buyer. No criteria resolvers (concrete token ids).
    function _fill(AdvancedOrder[] memory good, uint256[] memory prices, uint256 attemptedTotal, address recipient)
        private
        returns (bool[] memory available, uint256 actualSpent)
    {
        uint256 offerCount;
        uint256 consCount;
        for (uint256 i; i < good.length; ++i) {
            offerCount += good[i].parameters.offer.length;
            consCount += good[i].parameters.consideration.length;
        }
        (FulfillmentComponent[][] memory offerF, FulfillmentComponent[][] memory consF) =
            _fulfillments(good, offerCount, consCount);
        uint256 balBefore = address(this).balance;
        (available,) = ISeaport(SEAPORT).fulfillAvailableAdvancedOrders{value: attemptedTotal}(
            good, new CriteriaResolver[](0), offerF, consF, bytes32(0), recipient, good.length
        );
        for (uint256 i; i < good.length; ++i) {
            if (available[i]) actualSpent += prices[i];
        }
        // Seaport never takes more than the filled listings' price, so nothing owed is spent here
        if (address(this).balance + actualSpent < balBefore) revert BadOrder();
    }

    /// @dev Whether a listing is one the router will fulfil, and its native price. It must offer only concrete
    /// Credits ERC-721s, each an amount of exactly 1 (criteria items rejected), and ask only fixed native ETH (start ==
    /// end, so no ascending or descending auction can make the true cost differ) with a zero token and identifier, paid
    /// to anyone but this router. A listing that fails any check returns `ok == false` and is dropped from the batch. An order type other than FULL_OPEN (0) or FULL_RESTRICTED (2) reverts instead:
    /// OpenSea listings are never partial or contract orders, and a contract order's offerer may return less
    /// consideration than declared.
    function _checkOrder(OrderParameters memory p) private view returns (bool ok, uint256 price) {
        if (p.orderType != 0 && p.orderType != 2) revert UnsupportedOrderType();
        uint256 on = p.offer.length;
        if (on == 0) return (false, 0);
        for (uint256 i; i < on; ++i) {
            OfferItem memory it = p.offer[i];
            if (
                it.itemType != ItemType.ERC721 || it.token != address(credits) || it.startAmount != 1
                    || it.endAmount != 1
            ) return (false, 0);
        }
        uint256 cn = p.consideration.length;
        if (cn == 0) return (false, 0);
        for (uint256 i; i < cn; ++i) {
            ConsiderationItem memory it = p.consideration[i];
            if (
                it.itemType != ItemType.NATIVE || it.startAmount != it.endAmount || it.token != address(0)
                    || it.identifierOrCriteria != 0 || it.recipient == address(this)
            ) return (false, 0);
            price += it.startAmount;
        }
        if (price == 0) return (false, 0);
        ok = true;
    }

    /// @dev One singleton fulfillment group per offer item and per consideration item of the good listings, so each
    /// stays independent (no cross-order aggregation). Components for an order Seaport then skips are ignored.
    function _fulfillments(AdvancedOrder[] memory good, uint256 offerCount, uint256 consCount)
        private
        pure
        returns (FulfillmentComponent[][] memory offerF, FulfillmentComponent[][] memory consF)
    {
        offerF = new FulfillmentComponent[][](offerCount);
        consF = new FulfillmentComponent[][](consCount);
        uint256 oi;
        uint256 ci;
        for (uint256 i; i < good.length; ++i) {
            OrderParameters memory p = good[i].parameters;
            for (uint256 j; j < p.offer.length; ++j) {
                FulfillmentComponent[] memory grp = new FulfillmentComponent[](1);
                grp[0] = FulfillmentComponent({orderIndex: i, itemIndex: j});
                offerF[oi++] = grp;
            }
            for (uint256 j; j < p.consideration.length; ++j) {
                FulfillmentComponent[] memory grp = new FulfillmentComponent[](1);
                grp[0] = FulfillmentComponent({orderIndex: i, itemIndex: j});
                consF[ci++] = grp;
            }
        }
    }

    /// @dev The Credit ids actually bought: the offer ids of every good listing Seaport reports as executed.
    function _boughtIds(AdvancedOrder[] memory good, bool[] memory available) private pure returns (uint256[] memory ids) {
        uint256 count;
        for (uint256 i; i < good.length; ++i) {
            if (available[i]) count += good[i].parameters.offer.length;
        }
        ids = new uint256[](count);
        uint256 k;
        for (uint256 i; i < good.length; ++i) {
            if (!available[i]) continue;
            OfferItem[] memory offer = good[i].parameters.offer;
            for (uint256 j; j < offer.length; ++j) ids[k++] = offer[j].identifierOrCriteria;
        }
    }

    /// @notice Anyone: retries sending the dev wallet the dev fees a reverting dev wallet could not take earlier.
    function flushDevFee() external nonReentrant {
        _payDev(0);
    }

    /// @notice Anyone: retries sending the pool's owner the pre-launch fees it could not take earlier.
    function flushOwnerFee() external nonReentrant {
        _payOwner(0);
    }

    /// @dev Sends the pool's owner (read live, so it follows ownership transfers) `fee` plus any backlog, best-effort
    /// like `_payDev`: a failed send keeps the funds in the router in `ownerOwed`. Never reverts.
    function _payOwner(uint256 fee) private {
        uint256 owed = ownerOwed + fee;
        if (owed == 0) return;
        ownerOwed = 0;
        (bool ok,) = pool.owner().call{value: owed}("");
        if (!ok) ownerOwed = owed;
    }

    /// @dev Routes the 1% fee to the protocol's fee sinks: the dev part (the pool's live `devFeeBps`) to the dev
    /// wallet, then the remainder split in equal halves to the Burner and the Builder, the odd wei going to the Builder
    /// (`out - out/2`). The Burner and Builder are the protocol's own fee sinks and are always sent their halves; only
    /// the dev wallet send is best-effort (see `_payDev`), so a dev wallet that rejects ETH can never block a buy.
    /// dev + toBurner + toBuilder == fee, no dust.
    function _routeFee(uint256 fee) private {
        uint256 dev;
        if (fee != 0) {
            dev = fee * pool.devFeeBps() / BPS;
            uint256 out = fee - dev;
            uint256 toBurner = out / 2;
            uint256 toBuilder = out - toBurner;
            if (toBurner != 0) _sendEth(burner, toBurner);
            if (toBuilder != 0) _sendEth(builder, toBuilder);
        }
        _payDev(dev);
    }

    /// @dev Sends the dev wallet `dev` plus any backlog, best-effort: on a failed send the funds stay in the router,
    /// recorded in `devWalletOwed`, retried on the next routed fee or via `flushDevFee`. Never reverts, never
    /// misroutes. CEI: `devWalletOwed` is cleared before the external call.
    function _payDev(uint256 dev) private {
        uint256 owed = devWalletOwed + dev;
        if (owed == 0) return;
        devWalletOwed = 0;
        (bool ok,) = pool.devWallet().call{value: owed}("");
        if (!ok) devWalletOwed = owed;
    }

    function _sendEth(address to, uint256 value) private {
        (bool ok,) = to.call{value: value}("");
        if (!ok) revert SendFailed();
    }
}
