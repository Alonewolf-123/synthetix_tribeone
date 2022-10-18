pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./IPerpsV2MarketBaseTypes.sol";

// https://docs.synthetix.io/contracts/source/contracts/PerpsV2MarketState
interface IPerpsV2MarketState {
    function marketKey() external view returns (bytes32);

    function baseAsset() external view returns (bytes32);

    function marketSize() external view returns (uint128);

    function marketSkew() external view returns (int128);

    function fundingLastRecomputed() external view returns (uint32);

    function fundingSequence(uint) external view returns (int128);

    function positions(address) external view returns (IPerpsV2MarketBaseTypes.Position memory);

    function delayedOrders(address) external view returns (IPerpsV2MarketBaseTypes.DelayedOrder memory);

    function offchainDelayedOrders(address) external view returns (IPerpsV2MarketBaseTypes.OffchainDelayedOrder memory);

    function entryDebtCorrection() external view returns (int128);

    function nextPositionId() external view returns (uint64);

    function fundingSequenceLength() external view returns (uint);

    function getPositionAddressesPage(uint, uint) external view returns (address[] memory);

    function setMarketKey(bytes32) external;

    function setBaseAsset(bytes32) external;

    function setMarketSize(uint128) external;

    function setEntryDebtCorrection(int128) external;

    function setNextPositionId(uint64) external;

    function setMarketSkew(int128) external;

    function setFundingLastRecomputed(uint32) external;

    function pushFundingSequence(int128) external;

    function updatePosition(
        address account,
        uint64 id,
        uint64 lastFundingIndex,
        uint128 margin,
        uint128 lastPrice,
        int128 size
    ) external;

    function updateDelayedOrder(
        address account,
        int128 sizeDelta,
        uint128 targetRoundId,
        uint128 commitDeposit,
        uint128 keeperDeposit,
        uint256 executableAtTime,
        bytes32 trackingCode
    ) external;

    function updateOffchainDelayedOrder(
        address account,
        int128 sizeDelta,
        uint128 targetRoundId,
        uint128 commitDeposit,
        uint128 keeperDeposit,
        uint256 executableAtTime,
        uint256 latestPublishtime,
        bytes32 trackingCode
    ) external;

    function deletePosition(address) external;

    function deleteDelayedOrder(address) external;

    function deleteOffchainDelayedOrder(address) external;
}
