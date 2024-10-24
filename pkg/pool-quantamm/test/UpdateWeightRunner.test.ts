import * as dotenv from "dotenv";

import { expect } from "./chai-setup";
import {
  calculateCovariances,
  calculateGradient,
  calculatePrecision,
  calculateVariances,
} from "./helpers";
import { ethers, deployments } from "hardhat";
import { BigNumber } from "ethers";
import { fromBn, toBn } from "evm-bn";

describe("UpdateWeightRunner", () => {
  const abi = ethers.utils.defaultAbiCoder;
  let updateWeightRunner: any;

  async function setDefaultFees(vaultAdmin: any) {
    const [owner, account1, account2] = await ethers.getSigners();
    await vaultAdmin.setMinMaxTradingFees(1, 1 * 10_000);
    await vaultAdmin.setMinMaxFixedWithdrawalFees(1, 1 * 10_000);

    await vaultAdmin.setProtocolFixedWithdrawalFee(50);
    await vaultAdmin.setProtocolTradingFee(50);

    await vaultAdmin.setProtocolTradingFeeReceivingAddress(account2.address);
    await vaultAdmin.setProtocolFixedWithdrawalFeeReceivingAddress(
      account2.address
    );
  }

  async function deployUpdateWeightRunner() {
    const [owner, account1, account2] = await ethers.getSigners();
    const UpdateWeightRunner = await ethers.getContractFactory(
      "MockUpdateWeightRunner"
    );
    const updateWeightRunner = await UpdateWeightRunner.deploy(
      account2.address
    );
    return updateWeightRunner;
  }
  async function deployOracle(fixedValue: BigNumber, delay: Number) {
    const ChainlinkOracle = await ethers.getContractFactory(
      "MockChainlinkOracle"
    );
    const chainlinkOracle = await ChainlinkOracle.deploy(fixedValue, delay);
    return chainlinkOracle;
  }

  beforeEach(async function () {
    updateWeightRunner = await deployUpdateWeightRunner();
  });

  describe("Oracle Actions", () => {
    const fixedValue = ethers.utils.parseEther("1000");
    const delay = 3600;
    let chainlinkOracle: any;
    beforeEach(async function () {
      chainlinkOracle = await deployOracle(fixedValue, delay);
    });
    it("Owner should be able to add new oracle", async function () {
      const [owner, addr1, addr2] = await ethers.getSigners();
      await updateWeightRunner
        .connect(owner)
        .addOracle(chainlinkOracle.address);
      expect(
        await updateWeightRunner.approvedOracles(chainlinkOracle.address)
      ).to.be.equal(true);
    });
    it("Non-owner should not be able to add new oracle", async function () {
      const [owner, addr1, addr2] = await ethers.getSigners();
      await expect(
        updateWeightRunner.connect(addr1).addOracle(chainlinkOracle.address)
      ).to.be.revertedWith("OwnableUnauthorizedAccount");
    });
    it("Oracle cannot be added two times", async function () {
      const [owner, addr1, addr2] = await ethers.getSigners();
      await updateWeightRunner
        .connect(owner)
        .addOracle(chainlinkOracle.address);
      await expect(
        updateWeightRunner.connect(owner).addOracle(chainlinkOracle.address)
      ).to.be.revertedWith("Oracle already added");
    });
    it("Owner can remove existing oracle", async function () {
      const updateWeightRunner = await deployUpdateWeightRunner();
      const [owner, addr1, addr2] = await ethers.getSigners();
      await updateWeightRunner
        .connect(owner)
        .addOracle(chainlinkOracle.address);
      await updateWeightRunner
        .connect(owner)
        .removeOracle(chainlinkOracle.address);
      await expect(
        await updateWeightRunner.approvedOracles(chainlinkOracle.address)
      ).to.be.equal(false);
    });
    it("Non-owner cannot remove existing oracle", async function () {
      const updateWeightRunner = await deployUpdateWeightRunner();
      const [owner, addr1, addr2] = await ethers.getSigners();
      await updateWeightRunner
        .connect(owner)
        .addOracle(chainlinkOracle.address);
      await expect(
        updateWeightRunner.connect(addr1).removeOracle(chainlinkOracle.address)
      ).to.be.revertedWith("OwnableUnauthorizedAccount");
    });
  });

  describe("Set Rule Actions", () => {
    const fixedValue1 = ethers.utils.parseEther("1000");
    const fixedValue2 = ethers.utils.parseEther("1001");
    const fixedValue3 = ethers.utils.parseEther("1002");
    const delay = 3600;
    let chainlinkOracle1: any, chainlinkOracle2: any, chainlinkOracle3: any;
    let mockIdentityRule: any, mockPool: any;
    beforeEach(async function () {
      chainlinkOracle1 = await deployOracle(fixedValue1, delay);
      chainlinkOracle2 = await deployOracle(fixedValue2, delay);
      chainlinkOracle3 = await deployOracle(fixedValue3, delay);
      await updateWeightRunner.addOracle(chainlinkOracle1.address);
      await updateWeightRunner.addOracle(chainlinkOracle2.address);
      const MockIdentityRule = await ethers.getContractFactory(
        "MockIdentityRule"
      );
      mockIdentityRule = await MockIdentityRule.deploy();
      const MockPool = await ethers.getContractFactory("MockQuantAMMBasePool");
      const updateInterval = 1800;

      mockPool = await MockPool.deploy(
        updateInterval,
        updateWeightRunner.address
      );
    });

    it("set rule for pool - set pool oracles in runner", async function () {
      const poolOracles = [
        [chainlinkOracle1.address],
        [chainlinkOracle2.address],
      ];

      await updateWeightRunner.setRuleForPool(
        mockIdentityRule.address,
        poolOracles,
        [toBn("0.5")],
        [[toBn("2")]],
        toBn("0.9"),
        60,
        ethers.constants.AddressZero
      );

      let address = (await ethers.getSigners())[0].address;
      for (
        let i = 0;
        i < (await updateWeightRunner.getPoolOracleAndBackups(address)).length;
        ++i
      ) {
        expect(
          (await updateWeightRunner.getPoolOracleAndBackups(address))[i][0]
        ).to.eql(poolOracles[i][0]);
      }
    });

    it("set rule in pool - set pool settings", async function () {
      const poolOracles = [
        [chainlinkOracle1.address],
        [chainlinkOracle2.address],
      ];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      await updateWeightRunner.setRuleForPool(
        mockIdentityRule.address,
        poolOracles,
        lambdas,
        [[toBn("2")]],
        toBn("0.9"),
        60,
        ethers.constants.AddressZero
      );

      let address = (await ethers.getSigners())[0].address;
      for (
        let i = 0;
        i <
        (await updateWeightRunner.getPoolRuleSettings(address)).lambda.length;
        ++i
      ) {
        expect(
          (await updateWeightRunner.getPoolRuleSettings(address)).lambda[i]
        ).to.eql(lambdas[i]);
      }
      expect(
        (await updateWeightRunner.getPoolRuleSettings(address)).epsilonMax
      ).to.eql(toBn("0.9"));
      expect(
        (await updateWeightRunner.getPoolRuleSettings(address)).ruleParameters
      ).to.eql([[toBn("2")]]);
    });
    it("Set rule for pool - set rule", async function () {
      const poolOracles = [
        [chainlinkOracle1.address],
        [chainlinkOracle2.address],
      ];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      await updateWeightRunner.setRuleForPool(
        mockIdentityRule.address,
        poolOracles,
        lambdas,
        [[toBn("2")]],
        toBn("0.9"),
        60,
        ethers.constants.AddressZero
      );

      let address = (await ethers.getSigners())[0].address;
      const ruleData = await updateWeightRunner.getPoolRule(address);
      expect(ruleData).to.eql(mockIdentityRule.address);
    });
    it("Setting valid rule with 1 token and 1 non-existing oracle", async function () {
      const oracles = [[chainlinkOracle3.address]];
      const lambdas = [toBn("0.5"), toBn("0.5")];

      await expect(
        updateWeightRunner.setRuleForPool(
          mockIdentityRule.address,
          oracles,
          lambdas,
          [[toBn("2")]],
          toBn("0.9"),
          60,
          ethers.constants.AddressZero
        )
      ).to.be.revertedWith("Not approved oracled used");
    });
    it("Setting valid rule with 1 token, 1 existing and 1 non-existing oracle", async function () {
      const oracles = [[chainlinkOracle1.address], [chainlinkOracle3.address]];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      await expect(
        updateWeightRunner.setRuleForPool(
          mockIdentityRule.address,
          oracles,
          lambdas,
          [[toBn("2")]],
          toBn("0.9"),
          60,
          ethers.constants.AddressZero
        )
      ).to.be.revertedWith("Not approved oracled used");
    });
    it("Setting valid rule already set", async function () {
      const oracles = [[chainlinkOracle1.address], [chainlinkOracle2.address]];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      await updateWeightRunner.setRuleForPool(
        mockIdentityRule.address,
        oracles,
        lambdas,
        [[toBn("2")]],
        toBn("0.9"),
        60,
        ethers.constants.AddressZero
      );

      await expect(
        updateWeightRunner.setRuleForPool(
          mockIdentityRule.address,
          oracles,
          lambdas,
          [[toBn("2")]],
          toBn("0.9"),
          60,
          ethers.constants.AddressZero
        )
      ).to.be.revertedWith("Rule already set");
    });
    it("Setting valid rule with no oracles", async function () {
      const oracles = [[]];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      await expect(
        updateWeightRunner.setRuleForPool(
          mockIdentityRule.address,
          oracles,
          lambdas,
          [[toBn("2")]],
          toBn("0.9"),
          60,
          ethers.constants.AddressZero
        )
      ).to.be.revertedWith("Empty oracles array");
    });
    it("Setting valid rule, pool already set", async function () {
      const oracles: any = [];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      await expect(
        updateWeightRunner.setRuleForPool(
          mockIdentityRule.address,
          oracles,
          lambdas,
          [[toBn("2")]],
          toBn("0.9"),
          60,
          ethers.constants.AddressZero
        )
      ).to.be.revertedWith("Empty oracles array");
    });
  });
  describe("Update Actions", () => {
    const fixedValue1 = ethers.utils.parseEther("1000");
    const fixedValue2 = ethers.utils.parseEther("1001");
    const delay = 3600;
    const updateInterval = 1800;
    const fixedValue3 = ethers.utils.parseEther("1002");
    let chainlinkOracle1: any, chainlinkOracle2: any, chainlinkOracle3: any;
    let mockRule: any, mockPool: any;
    beforeEach(async function () {
      chainlinkOracle1 = await deployOracle(fixedValue1, delay);
      chainlinkOracle2 = await deployOracle(fixedValue2, delay);
      chainlinkOracle3 = await deployOracle(fixedValue3, delay);
      await updateWeightRunner.addOracle(chainlinkOracle1.address);
      await updateWeightRunner.addOracle(chainlinkOracle2.address);
      const MockRule = await ethers.getContractFactory("MockIdentityRule");
      mockRule = await MockRule.deploy();
      const MockPool = await ethers.getContractFactory("MockQuantAMMBasePool");
      mockPool = await MockPool.deploy(
        updateInterval,
        updateWeightRunner.address
      );
      const oracles = [[chainlinkOracle1.address], [chainlinkOracle2.address]];
      const lambdas = [toBn("0.5"), toBn("0.5")];
      const [owner, nonPool, addr2] = await ethers.getSigners();
      await mockPool.setRuleForPool(
        mockRule.address,
        oracles,
        lambdas,
        [[toBn("2")]],
        toBn("0.9"),
        60,
        owner.address
      );
    });
    it("Cannot run update for non-existing pool", async function () {
      const [owner, nonPool, addr2] = await ethers.getSigners();
      await expect(
        updateWeightRunner.performUpdate(nonPool.address)
      ).to.be.revertedWith("Pool not registered");
    });
    it("Cannot run update before updateInterval", async function () {
      const blockTime = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      await updateWeightRunner.InitialisePoolLastRunTime(
        mockPool.address,
        blockTime
      );
      await expect(
        updateWeightRunner.performUpdate(mockPool.address)
      ).to.be.revertedWith("Update not allowed");
    });
    it("Updates succesfully after updateInterval", async function () {
      await mockPool.setInitialWeights(
        [toBn("0.0000000005"), toBn("0.0000000005"), toBn("0"), toBn("0")]
      );
      const blockTime = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      await updateWeightRunner.performUpdate(mockPool.address);
      const now = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      expect(
        (await updateWeightRunner.getPoolRuleSettings(mockPool.address))
          .timingSettings.lastPoolUpdateRun
      ).to.be.equal(now);
      expect(await mockRule.CalculateNewWeightsCalled()).to.be.true;
    });

    it("Multiple consecutive updates successful", async function () {
      await mockPool.setInitialWeights(
        [toBn("0.0000000005"), toBn("0.0000000005"), toBn("0"), toBn("0")]
      );
      let blockTime = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      await updateWeightRunner.performUpdate(mockPool.address);
      let now = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      expect(
        (await updateWeightRunner.getPoolRuleSettings(mockPool.address))
          .timingSettings.lastPoolUpdateRun
      ).to.be.equal(now);
      expect(await mockRule.CalculateNewWeightsCalled()).to.be.true;
      await mockRule.SetCalculateNewWeightsCalled(false);
      expect(await mockRule.CalculateNewWeightsCalled()).to.be.false;
      await ethers.provider.send("evm_increaseTime", [updateInterval]);

      blockTime = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      await updateWeightRunner.performUpdate(mockPool.address);
      now = (
        await ethers.provider.getBlock(await ethers.provider.getBlockNumber())
      ).timestamp;
      expect(
        (await updateWeightRunner.getPoolRuleSettings(mockPool.address))
          .timingSettings.lastPoolUpdateRun
      ).to.be.equal(now);
      expect(await mockRule.CalculateNewWeightsCalled()).to.be.true;
    });
  });
});
