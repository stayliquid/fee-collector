import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("BeefyProxy", function () {   
    const INITIAL_SUPPLY = ethers.parseEther("1000000");
    const DEPOSIT_AMOUNT = ethers.parseEther("100");
    const WITHDRAW_PARTIAL = ethers.parseEther("50"); // Partial withdraw
    const FEE_PERCENTAGE = 20n; // 20% profit fee

    async function deployContractsFixtures() {
        const [ownerAddr, userAddr, beefyRouterAddr] = await ethers.getSigners();

        // Deploy Mock ERC20 Token
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const token = await MockERC20.deploy("MockToken", "MTK", INITIAL_SUPPLY);
        await token.waitForDeployment();
        const tokenAddr = await token.getAddress();

        // Deploy Mock BeefyZapRouter
        const MockBeefyZapRouter = await ethers.getContractFactory("MockBeefyZapRouter");
        const mockBeefyRouter = await MockBeefyZapRouter.deploy();
        await mockBeefyRouter.waitForDeployment();
        const mockBeefyRouterAddr = await mockBeefyRouter.getAddress();

        // Deploy BeefyProxy as an upgradeable contract
        const MockBeefyProxy = await ethers.getContractFactory("MockBeefyProxy");
        const beefyProxy = await upgrades.deployProxy(MockBeefyProxy, [mockBeefyRouterAddr, FEE_PERCENTAGE], {
            initializer: "initialize",
        });
        await beefyProxy.waitForDeployment();
        const beefyProxyAddr = await beefyProxy.getAddress();

        // Mint tokens to the user before testing deposits
        await token.mint(userAddr.address, DEPOSIT_AMOUNT);
        await token.mint(ownerAddr.address, ethers.parseEther("1000")); // Mint extra for fees

        return { token, mockBeefyRouter, beefyProxy, tokenAddr, mockBeefyRouterAddr, beefyProxyAddr, ownerAddr, userAddr, beefyRouterAddr };
    }

    it("Should deposit tokens and track user balance", async function () {
        const { token, beefyProxy, tokenAddr, beefyProxyAddr, userAddr } = await loadFixture(deployContractsFixtures);

        await token.connect(userAddr).approve(beefyProxyAddr, DEPOSIT_AMOUNT);

        await expect(
            beefyProxy.connect(userAddr).executeOrder(
                {
                    inputs: [{ token: tokenAddr, amount: DEPOSIT_AMOUNT }],
                    outputs: [{ token: tokenAddr, minOutputAmount: 0 }],
                    relay: { target: ethers.ZeroAddress, value: 0, data: "0x" },
                    user: userAddr,
                    recipient: userAddr
                },
                []
            )
        )
            .to.emit(beefyProxy, "DepositTracked")
            .withArgs(userAddr, tokenAddr, DEPOSIT_AMOUNT);

        expect(await beefyProxy.userDeposits(userAddr, tokenAddr)).to.equal(DEPOSIT_AMOUNT);
    });

    it("Should process a full withdrawal and deduct a fee", async function () {
        const { token, beefyProxy, tokenAddr, beefyProxyAddr, userAddr, ownerAddr } = await loadFixture(deployContractsFixtures);

        await token.connect(userAddr).approve(beefyProxyAddr, DEPOSIT_AMOUNT);
        await beefyProxy.connect(userAddr).executeOrder(
            {
                inputs: [{ token: tokenAddr, amount: DEPOSIT_AMOUNT }],
                outputs: [{ token: tokenAddr, minOutputAmount: 0 }],
                relay: { target: ethers.ZeroAddress, value: 0, data: "0x" },
                user: userAddr,
                recipient: userAddr
            },
            []
        );

        // Simulate Beefy returning increased amount (profit)
        const PROFIT = ethers.parseEther("20");
        const TOTAL_WITHDRAW = DEPOSIT_AMOUNT + PROFIT; // 120 tokens

        // Expected fee: 20% of 20 = 4 tokens
        const FEE = (PROFIT * FEE_PERCENTAGE) / 100n;
        const EXPECTED_AFTER_FEE = TOTAL_WITHDRAW - FEE;

        await token.connect(ownerAddr).transfer(beefyProxyAddr, TOTAL_WITHDRAW); // Simulate balance in contract

        await expect(beefyProxy.connect(userAddr).processWithdrawal(tokenAddr, TOTAL_WITHDRAW))
            .to.emit(beefyProxy, "WithdrawalProcessed")
            .withArgs(userAddr, tokenAddr, TOTAL_WITHDRAW, PROFIT, FEE);

        expect(await token.balanceOf(userAddr)).to.equal(EXPECTED_AFTER_FEE);
        expect(await beefyProxy.accumulatedFees(tokenAddr)).to.equal(FEE);
    });

    it("Should allow only the owner to withdraw fees", async function () {
        const { token, beefyProxy, tokenAddr, beefyProxyAddr, userAddr, ownerAddr } = await loadFixture(deployContractsFixtures);

        const FEE_AMOUNT = ethers.parseEther("10");

        await token.connect(ownerAddr).transfer(beefyProxyAddr, FEE_AMOUNT);

        await beefyProxy.connect(ownerAddr).setAccumulatedFees(tokenAddr, FEE_AMOUNT);

        await expect(beefyProxy.connect(userAddr).withdrawFees(tokenAddr))
            .to.be.revertedWithCustomError(beefyProxy, "OwnableUnauthorizedAccount")
            .withArgs(userAddr.address);
        
        const ownerBalanceBefore = await token.balanceOf(ownerAddr);

        await expect(beefyProxy.connect(ownerAddr).withdrawFees(tokenAddr))
            .to.emit(beefyProxy, "FeeWithdrawn")
            .withArgs(tokenAddr, FEE_AMOUNT);

        expect(await token.balanceOf(ownerAddr)).to.equal(ownerBalanceBefore + FEE_AMOUNT);
    });

    it("Should allow emergency pause and unpause", async function () {
        const { beefyProxy, token, tokenAddr, userAddr, ownerAddr } = await loadFixture(deployContractsFixtures);

        await expect(beefyProxy.connect(ownerAddr).activateEmergencyMode())
            .to.emit(beefyProxy, "EmergencyModeActivated");

        await expect(
            beefyProxy.connect(userAddr).executeOrder(
                {
                    inputs: [{ token: tokenAddr, amount: DEPOSIT_AMOUNT }],
                    outputs: [{ token: tokenAddr, minOutputAmount: 0 }],
                    relay: { target: ethers.ZeroAddress, value: 0, data: "0x" },
                    user: userAddr,
                    recipient: userAddr
                },
                []
            )
        ).to.be.revertedWithCustomError(beefyProxy, "EnforcedPause");

        await expect(beefyProxy.connect(ownerAddr).deactivateEmergencyMode())
            .to.emit(beefyProxy, "EmergencyModeDeactivated");
    });

    it("Should allow emergency withdrawal only when paused", async function () {
        const { beefyProxy, token, tokenAddr, beefyProxyAddr, ownerAddr } = await loadFixture(deployContractsFixtures);

        await expect(beefyProxy.connect(ownerAddr).emergencyWithdraw(tokenAddr)).to.be.revertedWithCustomError(beefyProxy, "ExpectedPause");

        await beefyProxy.connect(ownerAddr).activateEmergencyMode();

        await token.connect(ownerAddr).transfer(beefyProxyAddr, ethers.parseEther("50"));
        await expect(beefyProxy.connect(ownerAddr).emergencyWithdraw(tokenAddr))
            .to.emit(beefyProxy, "EmergencyWithdrawal")
            .withArgs(tokenAddr, ethers.parseEther("50"));
    });

});