const { ethers } = require("hardhat");
const { describe } = require("mocha");
let chai = require("chai");
chai.use(require("chai-as-promised"));
const { assert, expect } = chai;
const { BigNumber } = ethers;
const { parseEther } = ethers.utils;

const ETH_BALANCE_THRESHOLD = parseEther("0.0001");

let divTracker;
let owner;
let rewardAcct1; // Owns 60% of the supply.
let rewardAcct2; // Owns 40% of the supply.
let noRewardAcct;

async function setUp() {
  const IterableMapping = await ethers.getContractFactory("IterableMapping");
  const iterableMapping = await IterableMapping.deploy();
  await iterableMapping.deployed();

  const KATADividendTracker = await ethers.getContractFactory(
    "KATADividendTracker",
    {
      libraries: {
        IterableMapping: iterableMapping.address,
      },
    }
  );
  divTracker = await KATADividendTracker.deploy();
  await divTracker.deployed();

  [owner, rewardAcct1, rewardAcct2, noRewardAcct] = await ethers.getSigners();
}

describe("KATADividendTracker", function () {
  before(setUp);

  describe("Temporary state changes", function () {
    before(setUp);

    it("should allow owner to update claim wait time", async function () {
      await expect(divTracker.updateClaimWait(7200)).to.eventually.be.fulfilled;
      await expect(divTracker.claimWait()).to.eventually.equal(7200);
    });

    it("should allow updating gas fee for ETH transfers", async function () {
      await expect(divTracker.gasForTransfer()).to.eventually.equal(
        BigNumber.from(3000)
      );

      const tx = expect(divTracker.updateGasForTransfer(3001));
      await tx.to
        .emit(divTracker, "GasForTransferUpdated")
        .withArgs(BigNumber.from(3001), BigNumber.from(3000));
      await tx.to.eventually.be.fulfilled;

      await expect(divTracker.gasForTransfer()).to.eventually.equal(
        BigNumber.from(3001)
      );
    });
  });

  it("should use 18 decimals", async function () {
    await expect(divTracker.decimals()).to.eventually.equal(BigNumber.from(18));
  });

  it("should have no token holders", async function () {
    await expect(divTracker.getNumberOfTokenHolders()).to.eventually.equal(0);
  });

  it("should have no index processed", async function () {
    await expect(divTracker.getLastProcessedIndex()).to.eventually.equal(0);
  });

  it("should not allow withdrawDividend", async function () {
    await expect(divTracker.withdrawDividend()).to.eventually.be.rejected;
  });

  it("requires 10k tokens to be eligible for dividends", async function () {
    await expect(
      divTracker.MIN_TOKEN_BALANCE_FOR_DIVIDENDS()
    ).to.eventually.equal(parseEther("10000"));
  });

  it("should not exclude account from dividends by default", async function () {
    await expect(divTracker.excludedFromDividends(rewardAcct1.address)).to
      .eventually.be.false;
    await expect(divTracker.excludedFromDividends(rewardAcct2.address)).to
      .eventually.be.false;
  });

  it("should allow excluding accounts from dividends", async function () {
    await expect(divTracker.excludedFromDividends(noRewardAcct.address)).to
      .eventually.be.false;
    await expect(divTracker.excludeFromDividends(noRewardAcct.address)).to
      .eventually.be.fulfilled;
    await expect(divTracker.excludedFromDividends(noRewardAcct.address)).to
      .eventually.be.true;
  });

  it("should have claim wait set to 1 hour by default", async function () {
    await expect(divTracker.claimWait()).to.eventually.equal(3600);
  });

  it("should reject invalid claim wait time", async function () {
    await expect(divTracker.updateClaimWait(3599)).to.eventually.be.rejected;
    await expect(divTracker.updateClaimWait(86401)).to.eventually.be.rejected;
  });

  it("should set the account balance", async function () {
    // rewardAcct1 has 60k tokens.
    await expect(
      divTracker.balanceOf(rewardAcct1.address)
    ).to.eventually.be.equal(BigNumber.from(0));
    await expect(
      divTracker.setBalance(rewardAcct1.address, parseEther("60000"))
    ).to.eventually.be.fulfilled;
    await expect(
      divTracker.balanceOf(rewardAcct1.address)
    ).to.eventually.be.equal(parseEther("60000"));

    // rewardAcct2 has 40k tokens.
    await expect(
      divTracker.balanceOf(rewardAcct2.address)
    ).to.eventually.be.equal(BigNumber.from(0));
    await expect(
      divTracker.setBalance(rewardAcct2.address, parseEther("40000"))
    ).to.eventually.be.fulfilled;
    await expect(
      divTracker.balanceOf(rewardAcct2.address)
    ).to.eventually.be.equal(parseEther("40000"));
  });

  it("should reset rewards if balance goes below threshold", async function () {
    await expect(divTracker.setBalance(owner.address, parseEther("10000"))).to
      .eventually.be.fulfilled;
    await expect(divTracker.balanceOf(owner.address)).to.eventually.be.equal(
      parseEther("10000")
    );
    await expect(divTracker.setBalance(owner.address, parseEther("9999"))).to
      .eventually.be.fulfilled;
    await expect(divTracker.balanceOf(owner.address)).to.eventually.be.equal(
      BigNumber.from(0)
    );
  });

  it("should receive ETH", async function () {
    await expect(
      owner.sendTransaction({
        to: divTracker.address,
        value: parseEther("5"),
      })
    ).to.eventually.be.fulfilled;
    await expect(
      ethers.provider.getBalance(divTracker.address)
    ).to.eventually.be.equal(parseEther("5"));
  });

  it("should not process rewards when not enough gas", async function () {
    await expect(divTracker.getLastProcessedIndex()).to.eventually.equal(0);
    await expect(divTracker.process(0)).to.eventually.be.fulfilled;
    await expect(divTracker.getLastProcessedIndex()).to.eventually.equal(0);
  });

  it("should distribute dividends in ETH", async function () {
    await expect(divTracker.getNumberOfTokenHolders()).to.eventually.equal(2);

    const initBal1 = await ethers.provider.getBalance(rewardAcct1.address);
    const initBal2 = await ethers.provider.getBalance(rewardAcct2.address);
    await expect(divTracker.process(300000)).to.emit(divTracker, "Claim");
    const newBal1 = await ethers.provider.getBalance(rewardAcct1.address);
    const newBal2 = await ethers.provider.getBalance(rewardAcct2.address);

    assert.isTrue(
      parseEther("3").sub(newBal1.sub(initBal1)).lt(ETH_BALANCE_THRESHOLD)
    );
    assert.isTrue(
      parseEther("2").sub(newBal2.sub(initBal2)).lt(ETH_BALANCE_THRESHOLD)
    );
  });

  it("should get account by index", async function () {
    const [
      acct,
      index,
      iterationsUntilProcessed,
      withdrawableDividends,
      totalDividends,
      lastClaimTime,
      nextClaimTime,
      secondsUntilAutoClaimAvailable,
    ] = await divTracker.getAccountAtIndex(0);

    assert.equal(acct, rewardAcct1.address);
    assert.equal(index.toNumber(), 0);
    assert.equal(iterationsUntilProcessed.toNumber(), 2);
    assert.equal(withdrawableDividends.toNumber(), 0);
    assert.isAtMost(totalDividends, parseEther("3"));
    assert.isTrue(
      parseEther("3").sub(totalDividends).lt(ETH_BALANCE_THRESHOLD)
    );
    assert.isTrue(lastClaimTime.toNumber() > 0);
    assert.isTrue(nextClaimTime > lastClaimTime);
    assert.equal(nextClaimTime - lastClaimTime, 3600);
    assert.equal(secondsUntilAutoClaimAvailable, 3600);
  });

  it("should get account by address", async function () {
    const [
      acct,
      index,
      iterationsUntilProcessed,
      withdrawableDividends,
      totalDividends,
      lastClaimTime,
      nextClaimTime,
      secondsUntilAutoClaimAvailable,
    ] = await divTracker.getAccount(rewardAcct2.address);

    assert.equal(rewardAcct2.address, acct);
    assert.equal(index.toNumber(), 1);
    assert.equal(iterationsUntilProcessed.toNumber(), 1);
    assert.equal(withdrawableDividends.toNumber(), 0);
    assert.isAtMost(totalDividends, parseEther("2"));
    assert.isTrue(
      parseEther("2").sub(totalDividends).lt(ETH_BALANCE_THRESHOLD)
    );
    assert.isTrue(lastClaimTime.toNumber() > 0);
    assert.isTrue(nextClaimTime > lastClaimTime);
    assert.equal(nextClaimTime - lastClaimTime, 3600);
    assert.equal(secondsUntilAutoClaimAvailable, 3600);
  });

  it("should return the total dividends distributed", async function () {
    await expect(divTracker.totalDividendsDistributed()).to.eventually.equal(
      parseEther("5")
    );
  });

  it("should return the withdrawable rewards of an account", async function () {
    await expect(
      divTracker.withdrawableDividendOf(rewardAcct1.address)
    ).to.eventually.equal(BigNumber.from(0));
    await expect(
      divTracker.withdrawableDividendOf(rewardAcct2.address)
    ).to.eventually.equal(BigNumber.from(0));
    await expect(
      divTracker.withdrawableDividendOf(noRewardAcct.address)
    ).to.eventually.equal(BigNumber.from(0));

    await expect(
      owner.sendTransaction({
        to: await divTracker.address,
        value: parseEther("10"),
      })
    ).to.eventually.be.fulfilled;

    await expect(
      divTracker.withdrawableDividendOf(rewardAcct1.address)
    ).to.eventually.equal(parseEther("6"));
    await expect(
      divTracker.withdrawableDividendOf(rewardAcct2.address)
    ).to.eventually.equal(parseEther("4"));
    await expect(
      divTracker.withdrawableDividendOf(noRewardAcct.address)
    ).to.eventually.equal(BigNumber.from(0));
  });

  it("should redistribute for another round", async function () {
    const nextValidClaimTime = Date.now() / 1000 + 3600;
    await ethers.provider.send("evm_setNextBlockTimestamp", [
      nextValidClaimTime + 60, // 60 seconds allowance.
    ]);
    await ethers.provider.send("evm_mine", []);

    const initBal1 = await ethers.provider.getBalance(rewardAcct1.address);
    const initBal2 = await ethers.provider.getBalance(rewardAcct2.address);
    await expect(divTracker.process(300000)).to.emit(divTracker, "Claim");
    const newBal1 = await ethers.provider.getBalance(rewardAcct1.address);
    const newBal2 = await ethers.provider.getBalance(rewardAcct2.address);

    assert.isTrue(
      parseEther("6").sub(newBal1.sub(initBal1)).lt(ETH_BALANCE_THRESHOLD)
    );
    assert.isTrue(
      parseEther("4").sub(newBal2.sub(initBal2)).lt(ETH_BALANCE_THRESHOLD)
    );
  });
});
