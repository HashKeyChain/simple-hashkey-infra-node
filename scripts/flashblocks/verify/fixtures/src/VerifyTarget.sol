// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice P2 交易覆盖测试用的最小合约，由 p2-txs.sh 部署并调用。
/// 三种路径各覆盖一类执行结果：写存储 + 发事件、纯读、主动 revert。
contract VerifyTarget {
    uint256 public value;

    event ValueSet(address indexed sender, uint256 value);

    function set(uint256 x) external {
        value = x;
        emit ValueSet(msg.sender, x);
    }

    /// @dev 用于验证失败交易也能被两侧一致地打包（status=0，但仍上链）。
    function boom() external pure {
        revert("boom");
    }
}
