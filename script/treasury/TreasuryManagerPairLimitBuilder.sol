// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TreasuryManager } from "../../src/helpers/TreasuryManager.sol";

/// @dev Shared helper for `TreasuryManager.PairLimitInput` rows in `script/treasury/chains/*.s.sol`.
library TreasuryManagerPairLimitBuilder {
    /// @notice One enabled pair with max slippage / price impact (1e18 = 1%).
    function pair(
        address _tokenFrom,
        address _tokenTo,
        uint120 _maxSlippage,
        uint120 _maxPriceImpact
    )
        internal
        pure
        returns (TreasuryManager.PairLimitInput memory out_)
    {
        out_ = TreasuryManager.PairLimitInput({
            tokenFrom: IERC20(_tokenFrom),
            tokenTo: IERC20(_tokenTo),
            limit: TreasuryManager.PairLimit({ maxSlippage: _maxSlippage, maxPriceImpact: _maxPriceImpact, enabled: true })
        });
    }
}
