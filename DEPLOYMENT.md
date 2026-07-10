# 开发与部署指南

## 环境准备

### 方案一：使用 Hardhat（推荐新手）

**1. 初始化项目**

```bash
mkdir mini-demo-0 && cd mini-demo-0
npm init -y
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npx hardhat init
# 选择 "Create a JavaScript project"
```

**2. 安装依赖**

```bash
npm install @openzeppelin/contracts
```

**3. 配置 hardhat.config.js**

```javascript
require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: "0.8.20",
  networks: {
    // Sepolia 测试网示例
    sepolia: {
      url: "https://rpc.sepolia.org",  // 或使用 Alchemy/Infura RPC
      accounts: [process.env.PRIVATE_KEY],  // 你的测试网钱包私钥
    },
    // Monad Testnet 示例（如果已开放）
    monad: {
      url: "https://testnet-rpc.monad.xyz",
      accounts: [process.env.PRIVATE_KEY],
    },
  },
};
```

**4. 编译合约**

```bash
npx hardhat compile
```

**5. 编写部署脚本 `scripts/deploy.js`**

```javascript
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);

  // 部署 MockERC20
  const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
  const token = await MockERC20.deploy("TestToken", "TT");
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  console.log("MockERC20 deployed to:", tokenAddress);

  // 给部署者铸造一些测试代币
  const mintAmount = hre.ethers.parseEther("10000");  // 10,000 TT
  await token.mint(deployer.address, mintAmount);
  console.log("Minted 10,000 TT to deployer");

  // 部署 HarbergerTitleNFT
  // 参数：paymentToken, taxRateBps (1000 = 10%), floorPrice (10 TT)
  const HarbergerNFT = await hre.ethers.getContractFactory("HarbergerTitleNFT");
  const nft = await HarbergerNFT.deploy(
    tokenAddress,
    1000,  // 10% 年化税率
    hre.ethers.parseEther("10")  // 基准价 10 TOKEN
  );
  await nft.waitForDeployment();
  console.log("HarbergerTitleNFT deployed to:", await nft.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

**6. 部署到测试网**

```bash
# 先设置环境变量
export PRIVATE_KEY="你的测试网钱包私钥"

# 部署到 Sepolia
npx hardhat run scripts/deploy.js --network sepolia

# 或部署到本地 Hardhat 网络（用于快速测试）
npx hardhat run scripts/deploy.js
```

---

### 方案二：使用 Foundry（推荐有经验者）

**1. 初始化项目**

```bash
mkdir mini-demo-0 && cd mini-demo-0
forge init --no-commit
```

**2. 安装 OpenZeppelin**

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

**3. 配置 remappings**

在 `foundry.toml` 中添加：

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.20"

remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/"
]
```

**4. 将合约文件放入 `src/` 目录**

```bash
cp /path/to/MockERC20.sol src/
cp /path/to/HarbergerTitleNFT.sol src/
```

**5. 编译**

```bash
forge build
```

**6. 编写部署脚本 `script/Deploy.s.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MockERC20.sol";
import "../src/HarbergerTitleNFT.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 部署 MockERC20
        MockERC20 token = new MockERC20("TestToken", "TT");
        console.log("MockERC20 deployed to:", address(token));

        // 铸造测试代币
        token.mint(vm.addr(deployerPrivateKey), 10000 ether);

        // 部署 HarbergerTitleNFT
        HarbergerTitleNFT nft = new HarbergerTitleNFT(
            address(token),
            1000,        // 10% 年化税率
            10 ether     // 基准价 10 TOKEN
        );
        console.log("HarbergerTitleNFT deployed to:", address(nft));

        vm.stopBroadcast();
    }
}
```

**7. 部署**

```bash
# 本地测试
forge script script/Deploy.s.sol --fork-url http://localhost:8545 --broadcast

# 部署到 Sepolia
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

---

## 部署后的验证操作

部署完成后，可以用以下命令与合约交互：

### 使用 Hardhat Console

```bash
npx hardhat console --network sepolia
```

```javascript
// 获取合约实例（替换为实际地址）
const token = await ethers.getContractAt("MockERC20", "0x...");
const nft = await ethers.getContractAt("HarbergerTitleNFT", "0x...");

// 1. 授权合约使用代币
await token.approve(nft.target, ethers.parseEther("100"));

// 2. 铸造 NFT（价格 100 TOKEN，押金 10 TOKEN）
await nft.mint(ethers.parseEther("100"), ethers.parseEther("10"));

// 3. 查询状态
await nft.holder();           // 当前持有者
await nft.selfAssessedPrice(); // 当前价格
await nft.escrowBalance();     // 押金余额
await nft.owedTax();           // 当前欠税

// 4. 等待一段时间后查询欠税
await nft.owedTax();  // 会随着时间增加而增加
```

### 使用 Cast（Foundry 工具）

```bash
# 查询状态
cast call $NFT_ADDRESS "holder()(address)" --rpc-url $RPC_URL
cast call $NFT_ADDRESS "selfAssessedPrice()(uint256)" --rpc-url $RPC_URL
cast call $NFT_ADDRESS "owedTax()(uint256)" --rpc-url $RPC_URL

# 发送交易（需要设置 PRIVATE_KEY 环境变量）
cast send $TOKEN_ADDRESS "approve(address,uint256)(bool)" $NFT_ADDRESS 100000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
cast send $NFT_ADDRESS "mint(uint256,uint256)" 100000000000000000000 10000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

---

## 常见问题

### Q: 为什么我的 `owedTax()` 返回 0？

A: 可能是以下原因：
- 刚铸造完，还没有时间流逝
- 调用了 `setPrice()` 或 `depositCollateral()`，这两个函数会触发税金结算（惰性求值），结算后 `owedTax()` 会重置为 0，直到新的时间流逝

### Q: 为什么 `buyout()` 交易失败？

A: 检查以下几点：
- 你是否已经 `approve()` 了足够的代币给合约？
- 你传入的 `pricePayed` 是否 >= 当前 `selfAssessedPrice`？
- 你是否是当前持有者？（持有者不能买断自己的 NFT）

### Q: 如何在本地测试时间流逝？

A: 使用 Hardhat 的时间操纵工具：

```javascript
// 在 Hardhat Console 中快进 30 天
await network.provider.send("evm_increaseTime", [30 * 24 * 60 * 60]);
await network.provider.send("evm_mine");
```

或使用 Foundry 的 `vm.warp()`：

```solidity
vm.warp(block.timestamp + 30 days);
```
