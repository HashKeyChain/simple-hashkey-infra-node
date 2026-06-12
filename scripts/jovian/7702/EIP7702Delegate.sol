// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal delegate contract used by the EIP-7702 verifier.
/// @dev After an authority account delegates to this contract, an empty call to
///      the authority should execute this fallback and return MAGIC.
contract EIP7702Delegate {
    bytes32 internal constant MAGIC = 0x7702770277027702770277027702770277027702770277027702770277027702;

    function verifyEIP7702() external pure returns (bytes32) {
        return MAGIC;
    }

    fallback() external payable {
        bytes32 magic = MAGIC;
        assembly {
            mstore(0x00, magic)
            return(0x00, 0x20)
        }
    }
}
