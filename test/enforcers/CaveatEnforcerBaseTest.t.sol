// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity 0.8.23;

import { BaseTest } from "../utils/BaseTest.t.sol";
import { Implementation, SignatureType } from "../utils/Types.t.sol";
import { Counter } from "../utils/Counter.t.sol";
import { ICaveatEnforcer } from "../../src/interfaces/ICaveatEnforcer.sol";

abstract contract CaveatEnforcerBaseTest is BaseTest {
    constructor() {
        IMPLEMENTATION = Implementation.MultiSig;
        SIGNATURE_TYPE = SignatureType.MultiSig;
    }

    ////////////////////////////// State //////////////////////////////
    Counter public aliceDeleGatorCounter;
    Counter public bobDeleGatorCounter;
    Counter public carolDeleGatorCounter;
    Counter public daveDeleGatorCounter;

    ////////////////////////////// Set up //////////////////////////////

    function setUp() public virtual override {
        super.setUp();
        aliceDeleGatorCounter = new Counter(address(users.alice.deleGator));
        bobDeleGatorCounter = new Counter(address(users.bob.deleGator));
        carolDeleGatorCounter = new Counter(address(users.carol.deleGator));
        daveDeleGatorCounter = new Counter(address(users.dave.deleGator));
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _getEnforcer() internal virtual returns (ICaveatEnforcer);
}
