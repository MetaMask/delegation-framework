// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract CounterWithReceive is Ownable {
    ////////////////////////////// State //////////////////////////////

    uint256 public count = 0;

    ////////////////////////////// Constructor //////////////////////////////

    constructor(address _initialOwner) Ownable(_initialOwner) { }

    ////////////////////////////// External Methods //////////////////////////////

    function setCount(uint256 _newCount) public {
        count = _newCount;
    }

    function increment() public payable onlyOwner {
        count++;
    }

    function unsafeIncrement() public {
        count++;
    }
}
