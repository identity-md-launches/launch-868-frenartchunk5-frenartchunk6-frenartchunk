// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Test-only factory: measures CREATE2 with application initcode supplied as transaction calldata.
///      The deployment service must also simulate its actual factory's policy and overhead.
contract LaunchGasFactory {
    function deploy(bytes[] memory initCodes) external returns (address[] memory deployed) {
        deployed = new address[](initCodes.length);
        for (uint256 i; i < initCodes.length; ++i) {
            bytes memory code = initCodes[i];
            require(code.length > 0 && code.length <= 49_152, "invalid initcode");
            address application;
            assembly ("memory-safe") {
                application := create2(0, add(code, 32), mload(code), i)
            }
            require(application != address(0) && application.code.length > 0, "deployment failed");
            deployed[i] = application;
        }
    }
}
