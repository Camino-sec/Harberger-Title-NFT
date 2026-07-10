const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)));

  // 1. 部署 MockERC20
  console.log("\n--- Deploying MockERC20 ---");
  const MockERC20 = await hre.ethers.getContractFactory("MockERC20");
  const token = await MockERC20.deploy("TestToken", "TT");
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  console.log("MockERC20 deployed to:", tokenAddress);

  // 给部署者铸造测试代币
  const mintAmount = hre.ethers.parseEther("10000");
  await token.mint(deployer.address, mintAmount);
  console.log("Minted 10,000 TT to deployer");

  // 2. 部署 HarbergerTitleNFT
  console.log("\n--- Deploying HarbergerTitleNFT ---");
  const taxRateBps = 1000; // 10% 年化
  const floorPrice = hre.ethers.parseEther("10"); // 10 TOKEN

  const HarbergerNFT = await hre.ethers.getContractFactory("HarbergerTitleNFT");
  const nft = await HarbergerNFT.deploy(tokenAddress, taxRateBps, floorPrice);
  await nft.waitForDeployment();
  const nftAddress = await nft.getAddress();
  console.log("HarbergerTitleNFT deployed to:", nftAddress);

  // 3. 打印部署摘要
  console.log("\n=== Deployment Summary ===");
  console.log("MockERC20:          ", tokenAddress);
  console.log("HarbergerTitleNFT:  ", nftAddress);
  console.log("Tax Rate:           ", taxRateBps, "bps (10%)");
  console.log("Floor Price:        ", hre.ethers.formatEther(floorPrice), "TT");
  console.log("========================\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
