const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("HarbergerTitleNFT", function () {
  let token, nft;
  let owner, userA, userB, userC;

  const TAX_RATE_BPS = 1000; // 10% 年化
  const FLOOR_PRICE = ethers.parseEther("10"); // 10 TOKEN

  beforeEach(async function () {
    [owner, userA, userB, userC] = await ethers.getSigners();

    // 部署 MockERC20
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("TestToken", "TT");
    await token.waitForDeployment();

    // 给测试用户铸造代币
    await token.mint(userA.address, ethers.parseEther("1000"));
    await token.mint(userB.address, ethers.parseEther("1000"));
    await token.mint(userC.address, ethers.parseEther("1000"));

    // 部署 HarbergerTitleNFT
    const HarbergerNFT = await ethers.getContractFactory("HarbergerTitleNFT");
    nft = await HarbergerNFT.deploy(
      await token.getAddress(),
      TAX_RATE_BPS,
      FLOOR_PRICE
    );
    await nft.waitForDeployment();
  });

  describe("铸造（Mint）", function () {
    it("用户 A 铸造 NFT 并设定初始价格和押金", async function () {
      const price = ethers.parseEther("100");
      const deposit = ethers.parseEther("10");

      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(price, deposit);

      expect(await nft.holder()).to.equal(userA.address);
      expect(await nft.selfAssessedPrice()).to.equal(price);
      expect(await nft.escrowBalance()).to.equal(deposit);
    });

    it("不能重复铸造", async function () {
      const price = ethers.parseEther("100");
      const deposit = ethers.parseEther("10");

      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(price, deposit);

      await token.connect(userB).approve(await nft.getAddress(), deposit);
      await expect(nft.connect(userB).mint(price, deposit)).to.be.revertedWith("Already minted");
    });
  });

  describe("税金计算（惰性求值）", function () {
    beforeEach(async function () {
      const price = ethers.parseEther("100");
      const deposit = ethers.parseEther("10");
      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(price, deposit);
    });

    it("初始状态欠税为 0", async function () {
      expect(await nft.owedTax()).to.equal(0);
    });

    it("经过 180 天后欠税约为 4.93 TOKEN", async function () {
      // 快进 180 天
      await time.increase(180 * 24 * 60 * 60);

      const owed = await nft.owedTax();
      const expected = ethers.parseEther("4.93"); // 约 4.93 TOKEN

      // 允许 1% 的误差（因为时间戳不是精确的 180 天整）
      const tolerance = ethers.parseEther("0.1");
      expect(owed).to.be.closeTo(expected, tolerance);
    });

    it("经过 365 天后欠税约为 10 TOKEN（等于押金）", async function () {
      await time.increase(365 * 24 * 60 * 60);

      const owed = await nft.owedTax();
      const expected = ethers.parseEther("10");

      const tolerance = ethers.parseEther("0.1");
      expect(owed).to.be.closeTo(expected, tolerance);
    });
  });

  describe("充值押金（Deposit）", function () {
    beforeEach(async function () {
      const price = ethers.parseEther("100");
      const deposit = ethers.parseEther("5");
      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(price, deposit);
    });

    it("充值会先结算欠税再增加余额", async function () {
      // 快进 180 天（欠税约 4.93 TOKEN）
      await time.increase(180 * 24 * 60 * 60);

      // 充值 5 TOKEN
      const extraDeposit = ethers.parseEther("5");
      await token.connect(userA).approve(await nft.getAddress(), extraDeposit);
      await nft.connect(userA).depositCollateral(extraDeposit);

      // 净余额应该是：(5 - 4.93) + 5 ≈ 5.07 TOKEN
      const netBalance = await nft.netEscrowBalance();
      const expected = ethers.parseEther("5.07");
      const tolerance = ethers.parseEther("0.2");
      expect(netBalance).to.be.closeTo(expected, tolerance);
    });
  });

  describe("更新价格（Set Price）", function () {
    beforeEach(async function () {
      const price = ethers.parseEther("100");
      const deposit = ethers.parseEther("10");
      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(price, deposit);
    });

    it("持有者可以更新价格", async function () {
      const newPrice = ethers.parseEther("50");
      await nft.connect(userA).setPrice(newPrice);

      expect(await nft.selfAssessedPrice()).to.equal(newPrice);
    });

    it("非持有者不能更新价格", async function () {
      const newPrice = ethers.parseEther("50");
      await expect(nft.connect(userB).setPrice(newPrice)).to.be.revertedWith(
        "Only holder can set price"
      );
    });

    it("更新价格时会结算欠税", async function () {
      // 快进 180 天
      await time.increase(180 * 24 * 60 * 60);

      const escrowBefore = await nft.escrowBalance();
      await nft.connect(userA).setPrice(ethers.parseEther("50"));
      const escrowAfter = await nft.escrowBalance();

      // 押金应该减少了（扣除了税金）
      expect(escrowAfter).to.be.lessThan(escrowBefore);
    });
  });

  describe("强制买断（Buyout）", function () {
    const initialPrice = ethers.parseEther("100");
    const deposit = ethers.parseEther("10");

    beforeEach(async function () {
      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(initialPrice, deposit);
    });

    it("用户 B 可以强制买断 NFT", async function () {
      // 快进 200 天
      await time.increase(200 * 24 * 60 * 60);

      const buyoutPrice = ethers.parseEther("100");
      await token.connect(userB).approve(await nft.getAddress(), buyoutPrice);

      const aBalanceBefore = await token.balanceOf(userA.address);

      await nft.connect(userB).buyout(buyoutPrice);

      // 验证 NFT 转移
      expect(await nft.holder()).to.equal(userB.address);

      // 验证 A 收到了买断价格
      const aBalanceAfter = await token.balanceOf(userA.address);
      expect(aBalanceAfter - aBalanceBefore).to.be.greaterThan(0);
    });

    it("价格不足时不能买断", async function () {
      const lowPrice = ethers.parseEther("50");
      await token.connect(userB).approve(await nft.getAddress(), lowPrice);

      await expect(nft.connect(userB).buyout(lowPrice)).to.be.revertedWith(
        "Price too low"
      );
    });

    it("持有者不能买断自己的 NFT", async function () {
      await token.connect(userA).approve(await nft.getAddress(), initialPrice);

      await expect(nft.connect(userA).buyout(initialPrice)).to.be.revertedWith(
        "Holder cannot buyout own NFT"
      );
    });
  });

  describe("违约申领（Foreclosure）", function () {
    const initialPrice = ethers.parseEther("100");
    const deposit = ethers.parseEther("10");

    beforeEach(async function () {
      await token.connect(userA).approve(await nft.getAddress(), deposit);
      await nft.connect(userA).mint(initialPrice, deposit);
    });

    it("押金充足时不处于违约状态", async function () {
      await time.increase(100 * 24 * 60 * 60); // 100 天
      expect(await nft.foreclosed()).to.equal(false);
    });

    it("税金超过押金后进入违约状态", async function () {
      await time.increase(366 * 24 * 60 * 60); // 366 天
      expect(await nft.foreclosed()).to.equal(true);
    });

    it("违约后任何人都可以申领", async function () {
      await time.increase(366 * 24 * 60 * 60); // 366 天，进入违约

      const claimPrice = FLOOR_PRICE;
      await token.connect(userC).approve(await nft.getAddress(), claimPrice);
      await nft.connect(userC).claimForeclosed(claimPrice);

      expect(await nft.holder()).to.equal(userC.address);
      expect(await nft.foreclosed()).to.equal(false);
    });
  });
});
