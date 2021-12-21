const { strict: assert } = require('assert');

const KATA = artifacts.require("KATA");

const GENESIS = '0x0000000000000000000000000000000000000000';

const CONTRACTS = {
  PresaleClaim: process.env.PRESALE_CLAIM_ADDRESS,
  PrivateSale: process.env.PRESALE_ADDRESS,
  Seed: process.env.SEED_ADDRESS,
  Team: process.env.TEAM_ADDRESS,
  Development: process.env.DEVELOPMENT_ADDRESS,
  Marketing: process.env.MARKETING_ADDRESS,
  Airdrop: process.env.AIRDROP_ADDRESS,
  Treasury: process.env.TREASURY_ADDRESS,
}

module.exports = async function (deployer, _, accounts) {
  let allocations;

  const totalSupply = 50n * 10n**9n * 10n**18n;

  const percentage = (percent) => totalSupply * BigInt(percent * 1000) / (100n * 1000n);
  const network = await web3.eth.net.getId();

  if (process.env.NODE_ENV === 'production' || network === 0x05 || network == 0x04) {
    allocations = [
      // airdrop
      { address: CONTRACTS.Airdrop, tokens: percentage(1.00) },

      // development
      { address: CONTRACTS.Development, tokens: percentage(10.00) },

      // team
      { address: CONTRACTS.Team, tokens: percentage(15.00) },

      // marketing
      { address: CONTRACTS.Marketing, tokens: percentage(6.00) },

      // advisor
      { address: '0xd0E04fA0Ef76AaAA8F3e46a5DaBb8eA90531648f', tokens: percentage(6.00) },

      // treasury
      { address: CONTRACTS.Treasury, tokens: percentage(7.00) },

      // staking
      { address: '0x67380B7bBcaA81eF47A13434c0092739fc0E0BCb', tokens: percentage(15.00) },

      // in-game rewards
      { address: '0x4F8BF87BE6950c1728685899faDBB74CbBC4334C', tokens: percentage(14.00) },

      // dex
      { address: '0x0d0ba2FB3c3cd012f68e6d1023C2c33D03100d7E', tokens: percentage(5.00) },

      // bluezilla
      { address: '0x53F7bf4c358295b3B4fb6B78F9664bDC2fc96d27', tokens: percentage(6.00) - 100000000n * 10n**18n },

      // ibc
      { address: '0x309D3522F7C3a4fe6AC6bb8A2f3916d24C643DF7', tokens: 100000000n * 10n**18n },

      // seed
      { address: CONTRACTS.Seed, tokens: percentage(5.00) },

      // presale - private sale, ignition paid
      { address: CONTRACTS.PrivateSale, tokens: percentage(10.00) - 133351856152566738732191510n },

      // presale - katana presale
      { address: CONTRACTS.PresaleClaim, tokens: 133351856152566738732191510n },
    ]
  } else {
   allocations = [
     { address: accounts[0], tokens: totalSupply },
   ];
  }

  const totalAllocated = allocations.reduce((a, b) => a + b.tokens, 0n);
  const totalPercent = Number(totalAllocated * (100n * 1000n) / totalSupply) / 1000;

  assert(totalPercent === 100, `allocations must add up to 100% but is ${totalPercent}%`);
  assert(totalAllocated === totalSupply, `allocations must add up to ${totalSupply} but is ${totalAllocated}`);
  for (const k in CONTRACTS) {
    assert(!!CONTRACTS[k], `env.${k} is missing`);
  }
  console.log("Deploying from", accounts[0]);

  await deployer.deploy(
    KATA,
    allocations.map(({ address }) => address),
    allocations.map(({ tokens }) => tokens.toString())
  );

  const kata = await KATA.deployed();

  console.log("KATA deployed at:", kata.address);
};
