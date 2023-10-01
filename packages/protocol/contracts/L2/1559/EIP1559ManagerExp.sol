// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.20;

import { EssentialContract } from "../../common/EssentialContract.sol";
import { LibMath } from "../../libs/LibMath.sol";
import { LibFixedPointMath } from "../../thirdparty/LibFixedPointMath.sol";

import { EIP1559Manager } from "./EIP1559Manager.sol";

library Lib1559Exp {
    using LibMath for uint256;

    error EIP1559_OUT_OF_GAS();

    /// @dev Calculates xscale and yscale values used for pricing.
    /// @param gasExcessMax The maximum excess value.
    /// @param gasExcess The excess value.
    /// @param price The current price (base fee per gas).
    /// @param target The target gas value.
    /// @return xscale Calculated x scale value.
    /// @return yscale Calculated y scale value.
    function calculateScales(
        uint256 gasExcessMax,
        uint256 gasExcess,
        uint256 price,
        uint256 target
    )
        internal
        pure
        returns (uint256 xscale, uint256 yscale)
    {
        assert(gasExcess != 0 && gasExcessMax > gasExcess);
        // Calculate xscale
        xscale = LibFixedPointMath.MAX_EXP_INPUT / gasExcessMax;

        // Calculate yscale
        yscale = _calculatePrice(xscale, price, gasExcess, target);
    }

    function calcBaseFeePerGas(
        uint256 gasIssuePerSecond,
        uint256 xscale,
        uint256 yscale,
        uint256 gasExcessMin,
        uint256 gasExcess,
        uint256 blockTime,
        uint256 gasToBuy
    )
        internal
        view
        returns (uint256 _baseFeePerGas, uint256 _gasExcess)
    {
        uint256 issued = gasIssuePerSecond * blockTime;
        uint256 _gasExcessOld =
            (gasExcess.max(issued) - issued).max(gasExcessMin);
        _gasExcess = _gasExcessOld + gasToBuy;

        _baseFeePerGas =
            _calculatePrice(xscale, yscale, _gasExcessOld, gasToBuy);
    }

    function _calculatePrice(
        uint256 xscale,
        uint256 yscale,
        uint256 gasExcess,
        uint256 gasToBuy
    )
        private
        pure
        returns (uint256)
    {
        uint256 _gasToBuy = gasToBuy == 0 ? 1 : gasToBuy;
        uint256 _before = _calcY(gasExcess, xscale);
        uint256 _after = _calcY(gasExcess + _gasToBuy, xscale);
        return (_after - _before) / _gasToBuy / yscale;
    }

    function _calcY(uint256 x, uint256 xscale) private pure returns (uint256) {
        uint256 _x = x * xscale;
        if (_x >= LibFixedPointMath.MAX_EXP_INPUT) {
            revert EIP1559_OUT_OF_GAS();
        }
        return uint256(LibFixedPointMath.exp(int256(_x)));
    }
}

/// @title EIP1559ManagerExp
/// @notice Contract that implements EIP-1559 using
/// https://ethresear.ch/t/make-eip-1559-more-like-an-amm-curve/9082
contract EIP1559ManagerExp is EssentialContract, EIP1559Manager {
    using LibMath for uint256;

    // The following constants are generated by running:
    // ` forge test --mt test_1559_compare -vvv`
    uint256 public constant X_SCALE = 81_181_196;
    uint256 public constant Y_SCALE =
        468_197_597_051_383_201_929_023_136_841_316_354_317_482_152_382_098_864_832;
    uint256 public constant GAS_ISSUE_PER_SECOND = 1_666_666;
    uint64 public constant GAS_EXCESS = 1_666_666_000_000;
    uint64 public constant MIN_GAS_EXCESS = 1_666_716_000_000;

    uint128 public gasExcess;
    uint64 public parentTimestamp;
    uint256[49] private __gap;

    /// @notice Initializes the TaikoL2 contract.
    function init(address _addressManager) external initializer {
        EssentialContract._init(_addressManager);
        gasExcess = GAS_EXCESS;
        parentTimestamp = uint64(block.timestamp);

        emit BaseFeeUpdated(calcBaseFeePerGas(1));
    }

    /// @inheritdoc EIP1559Manager
    function updateBaseFeePerGas(uint32 gasUsed)
        external
        onlyFromNamed("taiko")
        returns (uint64 baseFeePerGas)
    {
        uint256 _baseFeePerGas;
        uint256 _gasExcess;
        (_baseFeePerGas, _gasExcess) = Lib1559Exp.calcBaseFeePerGas({
            gasIssuePerSecond: GAS_ISSUE_PER_SECOND,
            xscale: X_SCALE,
            yscale: Y_SCALE,
            gasExcessMin: MIN_GAS_EXCESS,
            gasExcess: gasExcess,
            blockTime: block.timestamp - parentTimestamp,
            gasToBuy: gasUsed
        });

        parentTimestamp = uint64(block.timestamp);
        gasExcess = uint128(_gasExcess.min(type(uint128).max));
        baseFeePerGas = uint64(_baseFeePerGas.min(type(uint64).max));

        emit BaseFeeUpdated(baseFeePerGas);
    }

    /// @inheritdoc EIP1559Manager
    function calcBaseFeePerGas(uint32 gasUsed) public view returns (uint64) {
        (uint256 _baseFeePerGas,) = Lib1559Exp.calcBaseFeePerGas({
            gasIssuePerSecond: GAS_ISSUE_PER_SECOND,
            xscale: X_SCALE,
            yscale: Y_SCALE,
            gasExcessMin: MIN_GAS_EXCESS,
            gasExcess: gasExcess,
            blockTime: block.timestamp - parentTimestamp,
            gasToBuy: gasUsed
        });

        return uint64(_baseFeePerGas.min(type(uint64).max));
    }
}