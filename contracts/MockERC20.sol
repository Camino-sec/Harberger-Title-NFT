// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC20
 * @notice 用于哈伯格税 NFT Demo 的模拟 ERC-20 代币。
 *         仅用于测试目的，Owner 可以随意铸造。
 */
contract MockERC20 is ERC20, Ownable {

    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /**
     * @notice 铸造代币（仅 Owner 可调用，方便测试网分发）
     * @param to 接收地址
     * @param amount 铸造数量
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
