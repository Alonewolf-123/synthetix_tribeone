pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

// Inheritance
import "./FuturesV2MarketProxyable.sol";

/*
 * Synthetic Futures
 * =================
 *
 * Futures markets allow users leveraged exposure to an asset, long or short.
 * A user must post some margin in order to open a futures account, and profits/losses are
 * continually tallied against this margin. If a user's margin runs out, then their position is closed
 * by a liquidation keeper, which is rewarded with a flat fee extracted from the margin.
 *
 * The Synthetix debt pool is effectively the counterparty to each trade, so if a particular position
 * is in profit, then the debt pool pays by issuing sUSD into their margin account,
 * while if the position makes a loss then the debt pool burns sUSD from the margin, reducing the
 * debt load in the system.
 *
 * As the debt pool underwrites all positions, the debt-inflation risk to the system is proportional to the
 * long-short skew in the market. It is therefore in the interest of the system to reduce the skew.
 * To encourage the minimisation of the skew, each position is charged a funding rate, which increases with
 * the size of the skew. The funding rate is charged continuously, and positions on the heavier side of the
 * market are charged the current funding rate times the notional value of their position, while positions
 * on the lighter side are paid at the same rate to keep their positions open.
 * As the funding rate is the same (but negated) on both sides of the market, there is an excess quantity of
 * funding being charged, which is collected by the debt pool, and serves to reduce the system debt.
 *
 * To combat front-running, the system does not confirm a user's order until the next price is received from
 * the oracle. Therefore opening a position is a three stage procedure: depositing margin, submitting an order,
 * and waiting for that order to be confirmed. The last transaction is performed by a keeper,
 * once a price update is detected.
 *
 * The contract architecture is as follows:
 *
 *     - FuturesV2Market.sol:         one of these exists per asset. Margin is maintained isolated per market.
 *
 *     - FuturesV2MarketManager.sol:  the manager keeps track of which markets exist, and is the main window between
 *                                  futures markets and the rest of the system. It accumulates the total debt
 *                                  over all markets, and issues and burns sUSD on each market's behalf.
 *
 *     - FuturesV2MarketSettings.sol: Holds the settings for each market in the global FlexibleStorage instance used
 *                                  by SystemSettings, and provides an interface to modify these values. Other than
 *                                  the base asset, these settings determine the behaviour of each market.
 *                                  See that contract for descriptions of the meanings of each setting.
 *
 * Each futures market and the manager operates behind a proxy, and for efficiency they communicate with one another
 * using their underlying implementations.
 *
 * Technical note: internal functions within the FuturesV2Market contract assume the following:
 *
 *     - prices passed into them are valid;
 *
 *     - funding has already been recomputed up to the current time (hence unrecorded funding is nil);
 *
 *     - the account being managed was not liquidated in the same transaction;
 */
// https://docs.synthetix.io/contracts/source/contracts/FuturesV2MarketMutations
contract FuturesV2MarketMutations is FuturesV2MarketProxyable {
    /* ========== CONSTRUCTOR ========== */

    constructor(
        address payable _proxy,
        address _marketState,
        address _owner,
        address _resolver
    ) public FuturesV2MarketProxyable(_proxy, _marketState, _owner, _resolver) {}

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * Pushes a new entry to the funding sequence at the current price and funding rate.
     * @dev Admin only method accessible to FuturesV2MarketSettings. This is admin only because:
     * - When system parameters change, funding should be recomputed, but system may be paused
     *   during that time for any reason, so this method needs to work even if system is paused.
     *   But in that case, it shouldn't be accessible to external accounts.
     */
    function recomputeFunding() external returns (uint lastIndex) {
        // only FuturesV2MarketSettings is allowed to use this method (calling it directly, not via proxy)
        _revertIfError(messageSender != _settings(), Status.NotPermitted);
        // This method is the only mutative method that uses the view _assetPrice()
        // and not the mutative _assetPriceRequireSystemChecks() that reverts on system flags.
        // This is because this method is used by system settings when changing funding related
        // parameters, so needs to function even when system / market is paused. E.g. to facilitate
        // market migration.
        (uint price, bool invalid) = _assetPrice();
        // A check for a valid price is still in place, to ensure that a system settings action
        // doesn't take place when the price is invalid (e.g. some oracle issue).
        require(!invalid, "Invalid price");
        return _recomputeFunding(price);
    }

    function _transferMargin(
        int marginDelta,
        uint price,
        address sender
    ) internal {
        // Transfer no tokens if marginDelta is 0
        uint absDelta = _abs(marginDelta);
        if (marginDelta > 0) {
            // A positive margin delta corresponds to a deposit, which will be burnt from their
            // sUSD balance and credited to their margin account.

            // Ensure we handle reclamation when burning tokens.
            uint postReclamationAmount = _manager().burnSUSD(sender, absDelta);
            if (postReclamationAmount != absDelta) {
                // If balance was insufficient, the actual delta will be smaller
                marginDelta = int(postReclamationAmount);
            }
        } else if (marginDelta < 0) {
            // A negative margin delta corresponds to a withdrawal, which will be minted into
            // their sUSD balance, and debited from their margin account.
            _manager().issueSUSD(sender, absDelta);
        } else {
            // Zero delta is a no-op
            return;
        }

        Position memory position = marketState.positions(sender);

        _updatePositionMargin(sender, position, price, marginDelta);

        proxy._emit(abi.encode(marginDelta), 2, MARGINTRANSFERRED_SIG, addressToBytes32(sender), 0, 0);

        emitPositionModified(position.id, sender, position.margin, position.size, 0, price, _latestFundingIndex(), 0);
    }

    /*
     * Alter the amount of margin in a position. A positive input triggers a deposit; a negative one, a
     * withdrawal. The margin will be burnt or issued directly into/out of the caller's sUSD wallet.
     * Reverts on deposit if the caller lacks a sufficient sUSD balance.
     * Reverts on withdrawal if the amount to be withdrawn would expose an open position to liquidation.
     */
    function transferMargin(int marginDelta) external onlyProxy {
        uint price = _assetPriceRequireSystemChecks();
        _recomputeFunding(price);
        _transferMargin(marginDelta, price, messageSender);
    }

    /*
     * Withdraws all accessible margin in a position. This will leave some remaining margin
     * in the account if the caller has a position open. Equivalent to `transferMargin(-accessibleMargin(sender))`.
     */
    function withdrawAllMargin() external onlyProxy {
        address sender = messageSender;
        uint price = _assetPriceRequireSystemChecks();
        _recomputeFunding(price);
        int marginDelta = -int(_accessibleMargin(marketState.positions(sender), price));
        _transferMargin(marginDelta, price, sender);
    }

    /*
     * Adjust the sender's position size.
     * Reverts if the resulting position is too large, outside the max leverage, or is liquidating.
     */
    function modifyPosition(int sizeDelta) external {
        _modifyPosition(sizeDelta, bytes32(0));
    }

    /*
     * Same as modifyPosition, but emits an event with the passed tracking code to
     * allow offchain calculations for fee sharing with originating integrations
     */
    function modifyPositionWithTracking(int sizeDelta, bytes32 trackingCode) external {
        _modifyPosition(sizeDelta, trackingCode);
    }

    function _modifyPosition(int sizeDelta, bytes32 trackingCode) internal onlyProxy {
        uint price = _assetPriceRequireSystemChecks();
        _recomputeFunding(price);
        _trade(
            messageSender,
            TradeParams({
                sizeDelta: sizeDelta,
                price: price,
                takerFee: _takerFee(marketState.marketKey()),
                makerFee: _makerFee(marketState.marketKey()),
                trackingCode: trackingCode
            })
        );
    }

    /*
     * Submit an order to close a position.
     */
    function closePosition() external {
        _closePosition(bytes32(0));
    }

    /// Same as closePosition, but emits an even with the trackingCode for volume source fee sharing
    function closePositionWithTracking(bytes32 trackingCode) external {
        _closePosition(trackingCode);
    }

    function _closePosition(bytes32 trackingCode) internal onlyProxy {
        int size = marketState.positions(messageSender).size;
        _revertIfError(size == 0, Status.NoPositionOpen);
        uint price = _assetPriceRequireSystemChecks();
        _recomputeFunding(price);
        _trade(
            messageSender,
            TradeParams({
                sizeDelta: -size,
                price: price,
                takerFee: _takerFee(marketState.marketKey()),
                makerFee: _makerFee(marketState.marketKey()),
                trackingCode: trackingCode
            })
        );
    }

    function _liquidatePosition(
        address account,
        address liquidator,
        uint price
    ) internal {
        Position memory position = marketState.positions(account);

        // get remaining margin for sending any leftover buffer to fee pool
        uint remMargin = _remainingMargin(position, price);

        // Record updates to market size and debt.
        int positionSize = position.size;
        uint positionId = position.id;
        marketState.setMarketSkew(int128(int(marketState.marketSkew()).sub(positionSize)));
        marketState.setMarketSize(uint128(uint(marketState.marketSize()).sub(_abs(positionSize))));

        uint fundingIndex = _latestFundingIndex();
        _applyDebtCorrection(
            Position(0, uint64(fundingIndex), 0, uint128(price), 0),
            Position(0, position.lastFundingIndex, position.margin, position.lastPrice, int128(positionSize))
        );

        // Close the position itself.
        marketState.deletePosition(account);

        // Issue the reward to the liquidator.
        uint liqFee = _liquidationFee(positionSize, price);
        _manager().issueSUSD(liquidator, liqFee);

        emitPositionModified(positionId, account, 0, 0, 0, price, fundingIndex, 0);
        proxy._emit(
            abi.encode(positionId, account, liquidator, positionSize, price, liqFee),
            1,
            POSITIONLIQUIDATED_SIG,
            0,
            0,
            0
        );

        // Send any positive margin buffer to the fee pool
        if (remMargin > liqFee) {
            _manager().payFee(remMargin.sub(liqFee));
        }
    }

    /*
     * Liquidate a position if its remaining margin is below the liquidation fee. This succeeds if and only if
     * `canLiquidate(account)` is true, and reverts otherwise.
     * Upon liquidation, the position will be closed, and the liquidation fee minted into the liquidator's account.
     */
    function liquidatePosition(address account) external onlyProxy {
        uint price = _assetPriceRequireSystemChecks();
        _recomputeFunding(price);

        _revertIfError(!_canLiquidate(marketState.positions(account), price), Status.CannotLiquidate);

        _liquidatePosition(account, messageSender, price);
    }

    /* ========== EVENTS ========== */
}