const { ethers } = require("hardhat");
const { BigNumber } = ethers;
const { MaxUint256 } = ethers.constants;
const { parseEther, formatEther } = ethers.utils;

// expect 1 ETH = 3000 USDT, 1 KATA = 0.00075 USDT (Public sale price)
const INITIAL_KATA_RESERVES = parseEther("4000000");
const INITIAL_ETH_RESERVES = parseEther("1");
const month = 2592000;  // 30 days

async function main() {
  console.log("Deploying IterableMapping contract...");

  const IterableMapping = await ethers.getContractFactory("IterableMapping");
  const iterableMapping = await IterableMapping.deploy();
  await iterableMapping.deployed();

  console.log("Deployed at:", iterableMapping.address)

  console.log("Deploying KATA coin contract...");

  const KATA = await ethers.getContractFactory("KATA", {
    libraries: {
      IterableMapping: iterableMapping.address,
    },
  });
  kata = await KATA.deploy();
  await kata.deployed();

  console.log("Deployed at:", kata.address)

  const [owner] = await ethers.getSigners();

  // Add initial liquidity.
  console.log("Adding liquidity to Uniswap...");

  const routerAddress = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D";
  let router = await ethers.getContractAt("IUniswapV2Router02", routerAddress);
  await kata.approve(routerAddress, MaxUint256)
  await router.addLiquidityETH(
    kata.address,
    INITIAL_KATA_RESERVES,
    parseEther("0"), // slippage is unavoidable
    parseEther("0"), // slippage is unavoidable
    owner.address,
    MaxUint256,
    { value: INITIAL_ETH_RESERVES }
  )

  console.log("Liquidity added to Uniswap.");

  const totalSupply = await kata.totalSupply();

  console.log("KATA coin has total supply of", formatEther(totalSupply));
  
  const vesting = async (name, cliff, duration, tge, percent, beneficiary) => {
    // Vesting Tokens
    console.log("Deploying a vesting contract for", name, "...");
    const TokenVesting = await ethers.getContractFactory("TokenVesting");
    const vesting = await TokenVesting.deploy(
      name,
      kata.address,
      beneficiary,
      0,      // use current time
      cliff * month,
      duration * month,
      tge,
      false   // revocable: false
    )
    await vesting.deployed();
    await kata.transfer(vesting.address, totalSupply.mul(percent).div(100));    // % of total supply
    console.log("Deployed at:", vesting.address);
  }

  await vesting("Game Development", 6, 24, 10, 15, owner.address);
  await vesting("Team", 6, 40, 10, 14, owner.address);
  await vesting("Operations", 6, 40, 0, 6, owner.address);
  await vesting("Marketing", 6, 40, 10, 9, owner.address);
  await vesting("Advisors", 6, 40, 10, 2, owner.address);
  await vesting("Charity", 0, 30, 0, 2, owner.address);
  await vesting("Treasury", 0, 33, 1, 10, owner.address);
  await vesting("In-Game Rewards", 6, 100, 0, 5, owner.address);
}


main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });