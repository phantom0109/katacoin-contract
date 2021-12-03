const KATA = artifacts.require("KATA");

module.exports = async function (deployer, _, accounts) {

  console.log("Deploying from", accounts[0]);
  
  await deployer.deploy(KATA);

  const kata = await KATA.deployed();
  console.log("KATA deployed at:", kata.address);
};
