// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {KipuBank} from "../src/KipuBank.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

contract KipuBankTest is Test {
    KipuBank public bank;
    MockUSDC public usdc;
    MockUniversalRouter public router;
    MockPermit2 public permit2;
    MockChainlinkAggregator public priceFeed;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    uint256 public constant BANK_CAP = 1_000_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        router = new MockUniversalRouter(address(usdc));
        permit2 = new MockPermit2();
        priceFeed = new MockChainlinkAggregator();

        vm.prank(admin);
        bank = new KipuBank(
            address(usdc),
            BANK_CAP,
            address(router),
            address(permit2),
            address(priceFeed),
            admin
        );

        // Mint enough USDC for users (including for bank cap tests)
        usdc.mint(user1, BANK_CAP + 50_000e6);
        usdc.mint(user2, 100_000e6);
    }

    // ========= Deployment =========

    function test_Deployment() public view {
        assertEq(address(bank.USDC()), address(usdc));
        assertEq(bank.BANK_CAP(), BANK_CAP);
        assertTrue(bank.hasRole(bank.MANAGER_ROLE(), admin));
    }

    function test_Constructor_RevertWhen_ZeroUsdc() public {
        vm.expectRevert(KipuBank.ZeroAddressNotAllowed.selector);
        new KipuBank(
            address(0),
            BANK_CAP,
            address(router),
            address(permit2),
            address(priceFeed),
            admin
        );
    }

    function test_Constructor_RevertWhen_ZeroAdmin() public {
        vm.expectRevert(KipuBank.ZeroAddressNotAllowed.selector);
        new KipuBank(
            address(usdc),
            BANK_CAP,
            address(router),
            address(permit2),
            address(priceFeed),
            address(0)
        );
    }

    function test_Constructor_RevertWhen_ZeroCap() public {
        vm.expectRevert(KipuBank.ZeroBankCapNotAllowed.selector);
        new KipuBank(
            address(usdc),
            0,
            address(router),
            address(permit2),
            address(priceFeed),
            admin
        );
    }

    // ========= USDC Deposits =========

    function test_DepositUSDC() public {
        uint256 amount = 1_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), amount);
        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(user1), amount);
        assertEq(bank.totalUsdcInVault(), amount);
    }

    function test_DepositUSDC_Multiple() public {
        vm.startPrank(user1);
        usdc.approve(address(bank), 3_000e6);
        bank.depositArbitraryToken(
            address(usdc),
            1_000e6,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        bank.depositArbitraryToken(
            address(usdc),
            2_000e6,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(user1), 3_000e6);
        assertEq(bank.depositCount(), 2);
    }

    function test_DepositUSDC_MultipleUsers() public {
        vm.startPrank(user1);
        usdc.approve(address(bank), 1_000e6);
        bank.depositArbitraryToken(
            address(usdc),
            1_000e6,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();

        vm.prank(user2);
        usdc.approve(address(bank), 2_000e6);
        vm.prank(user2);
        bank.depositArbitraryToken(
            address(usdc),
            2_000e6,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        assertEq(bank.balanceOfUsdc(user1), 1_000e6);
        assertEq(bank.balanceOfUsdc(user2), 2_000e6);
        assertEq(bank.totalUsdcInVault(), 3_000e6);
    }

    function test_DepositUSDC_RevertZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBank.ZeroAmountNotAllowed.selector);
        bank.depositArbitraryToken(
            address(usdc),
            0,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();
    }

    // ========= Withdrawals =========

    function test_Withdraw() public {
        uint256 deposit = 5_000e6;

        // Deposit
        vm.startPrank(user1);
        usdc.approve(address(bank), deposit);
        bank.depositArbitraryToken(
            address(usdc),
            deposit,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        // Withdraw
        uint256 balanceBefore = usdc.balanceOf(user1);
        bank.withdrawUsdc(2_000e6);
        uint256 balanceAfter = usdc.balanceOf(user1);

        assertEq(bank.balanceOfUsdc(user1), 3_000e6);
        assertEq(balanceAfter - balanceBefore, 2_000e6);
        assertEq(bank.withdrawCount(), 1);
        vm.stopPrank();
    }

    function test_Withdraw_Full() public {
        uint256 amount = 3_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), amount);
        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        bank.withdrawUsdc(amount);
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(user1), 0);
        assertEq(bank.totalUsdcInVault(), 0);
    }

    function test_Withdraw_RevertZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBank.ZeroAmountNotAllowed.selector);
        bank.withdrawUsdc(0);
        vm.stopPrank();
    }

    function test_Withdraw_RevertInsufficientBalance() public {
        vm.startPrank(user1);
        usdc.approve(address(bank), 1_000e6);
        bank.depositArbitraryToken(
            address(usdc),
            1_000e6,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        // Just expect revert without specific error
        vm.expectRevert();
        bank.withdrawUsdc(2_000e6);
        vm.stopPrank();
    }

    // ========= Bank Cap =========

    function test_BankCap() public {
        uint256 amount = 500_000e6; // 500k USDC, well under 1M cap
        vm.startPrank(user1);
        usdc.approve(address(bank), amount);
        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();

        assertEq(bank.totalUsdcInVault(), amount);
        assertEq(bank.remainingCapacityUsdc(), BANK_CAP - amount);
    }

    function test_BankCap_Exceed() public {
        // Deposit up to just under the cap
        uint256 firstDeposit = 500_000e6;
        uint256 secondDeposit = 501_000e6; // This would exceed the cap (500k + 501k = 1.001M > 1M)

        vm.startPrank(user1);
        usdc.approve(address(bank), firstDeposit + secondDeposit);

        // First deposit
        bank.depositArbitraryToken(
            address(usdc),
            firstDeposit,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        // Now try to deposit more which exceeds the cap
        vm.expectRevert(); // Just expect any revert
        bank.depositArbitraryToken(
            address(usdc),
            secondDeposit,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        vm.stopPrank();
    }

    function test_BankCap_WithdrawFreesCapacity() public {
        uint256 amount = 400_000e6;
        vm.startPrank(user1);
        usdc.approve(address(bank), amount);
        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        uint256 remainingBefore = bank.remainingCapacityUsdc();

        bank.withdrawUsdc(100e6);

        assertEq(bank.remainingCapacityUsdc(), remainingBefore + 100e6);
        vm.stopPrank();
    }

    // ========= Admin Functions =========

    function test_RecoverFunds() public {
        vm.prank(admin);
        bank.recoverFunds(user1, 10_000e6);

        assertEq(bank.balanceOfUsdc(user1), 10_000e6);
    }

    function test_RecoverFunds_NotManager() public {
        vm.prank(user1);
        vm.expectRevert();
        bank.recoverFunds(user2, 1_000e6);
    }

    // ========= Events =========

    function test_Event_DepositedUSDC() public {
        uint256 amount = 5_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), amount);

        vm.expectEmit(true, true, false, true);
        emit KipuBank.DepositedUSDC(user1, address(usdc), amount, amount);

        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();
    }

    function test_Event_WithdrawnUSDC() public {
        uint256 deposit = 7_000e6;
        uint256 withdraw = 2_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), deposit);
        bank.depositArbitraryToken(
            address(usdc),
            deposit,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );

        vm.expectEmit(true, false, false, true);
        emit KipuBank.WithdrawnUSDC(user1, withdraw);

        bank.withdrawUsdc(withdraw);
        vm.stopPrank();
    }

    function test_Event_FundsRecovered() public {
        vm.expectEmit(true, true, false, true);
        emit KipuBank.FundsRecovered(admin, user1, 15_000e6);

        vm.prank(admin);
        bank.recoverFunds(user1, 15_000e6);
    }

    // ========= View Functions =========

    function test_Views() public {
        vm.startPrank(user1);
        usdc.approve(address(bank), 5_000e6);
        bank.depositArbitraryToken(
            address(usdc),
            5_000e6,
            0,
            block.timestamp + 1,
            "",
            new bytes[](0)
        );
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(user1), 5_000e6);
        assertEq(bank.totalUsdcInVault(), 5_000e6);
        assertEq(bank.remainingCapacityUsdc(), BANK_CAP - 5_000e6);
        assertEq(bank.depositCount(), 1);
        assertEq(bank.withdrawCount(), 0);
    }

    function test_GetEthUsdPrice() public view {
        (int256 price, uint8 decimals) = bank.getEthUsdPrice();
        assertEq(price, 2000e8);
        assertEq(decimals, 8);
    }

    // ========= Direct ETH Transfer =========

    function test_Receive_RevertOnDirectETH() public {
        vm.deal(user1, 1 ether);

        vm.expectRevert("Use depositArbitraryToken with ETH_ALIAS");

        vm.prank(user1);
        address(bank).call{value: 1 ether}("");
    }
}
