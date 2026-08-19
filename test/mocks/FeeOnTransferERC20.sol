// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock ERC-20 that deducts a fee on every transfer for adversarial testing.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public feeBps;

    constructor(string memory _name, string memory _symbol, uint256 _feeBps) ERC20(_name, _symbol) {
        feeBps = _feeBps;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function _update(address _from, address _to, uint256 _value) internal override {
        if (_from != address(0) && _to != address(0) && feeBps > 0) {
            uint256 fee_ = (_value * feeBps) / 10_000;
            if (fee_ > 0) {
                super._update(_from, address(this), fee_);
                _value -= fee_;
            }
        }
        super._update(_from, _to, _value);
    }
}
