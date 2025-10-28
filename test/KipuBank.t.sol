// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {KipuBank} from "../src/KipuBank.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";
import {MockTokenA} from "./mocks/MockTokenA.sol";

contract KipuBankTest is Test {
    KipuBank public bank;
    MockUSDC public usdc;
    MockUniversalRouter public router;
    MockPermit2 public permit2;
    MockChainlinkAggregator public priceFeed;
    MockTokenA public tokenA;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    // BANK_CAP of 1,000,000 USDC (6 decimals)
    uint256 public constant BANK_CAP = 1_000_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        tokenA = new MockTokenA(); // generic ERC20 different from USDC
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

        // fund users
        usdc.mint(user1, BANK_CAP + 50_000e6);
        usdc.mint(user2, 100_000e6);
        tokenA.mint(user1, 1_000_000e18); // 18 decimals

        // connect mocks
        router.setVault(address(bank));
        router.setUsdc(address(usdc));
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

    // ========= USDC Deposits (classic approve + depositArbitraryToken) =========

    function test_DepositUSDC() public {
        uint256 amount = 1_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), amount);
        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0, // minUsdcOut
            block.timestamp + 1, // deadline
            bytes(""), // routerCommands
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
            bytes(""),
            new bytes[](0)
        );

        bank.depositArbitraryToken(
            address(usdc),
            2_000e6,
            0,
            block.timestamp + 1,
            bytes(""),
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
            bytes(""),
            new bytes[](0)
        );
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(bank), 2_000e6);
        bank.depositArbitraryToken(
            address(usdc),
            2_000e6,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0)
        );
        vm.stopPrank();

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
            bytes(""),
            new bytes[](0)
        );
        vm.stopPrank();
    }

    // ========= Permit2 Deposit (1-tx UX, no prior approve) =========

    function test_DepositWithPermit2_USDC() public {
        uint256 amount = 2_500e6;

        // ensure user1 has enough USDC
        usdc.mint(user1, amount);

        vm.startPrank(user1);
        bank.depositWithPermit2(
            address(usdc),
            amount,
            0, // minUsdcOut (no slippage for USDC)
            block.timestamp + 1, // deadline
            bytes(""), // routerCommands (no swap needed for USDC)
            new bytes[](0), // routerInputs
            27, // dummy v
            bytes32(0), // dummy r
            bytes32(0) // dummy s
        );
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(user1), amount);
        assertEq(bank.totalUsdcInVault(), amount);
        assertEq(bank.depositCount(), 1);
    }

    function test_DepositWithPermit2_RejectETH() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBank.ZeroAddressNotAllowed.selector);
        bank.depositWithPermit2(
            address(0), // forbidden path for Permit2 (ETH or zero address)
            1e18,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0),
            27,
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();
    }

    // ========= Slippage guard for token != USDC =========
    // We simulate a deposit with tokenA (not USDC). The router "swaps" and
    // mints simulatedSwapOutput USDC to the vault. If that output is less
    // than minUsdcOut, the call should revert with InsufficientSwapOutput.

    function test_DepositNonUSDC_RevertOnSlippage() public {
        uint256 amountInTokenA = 1_000e18;

        vm.startPrank(user1);
        tokenA.approve(address(bank), amountInTokenA);

        // simulate a bad route: only 900e6 USDC will be minted to the vault
        router.setSimulatedSwapOutput(900e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBank.InsufficientSwapOutput.selector,
                1_000e6,
                900e6
            )
        );

        bank.depositArbitraryToken(
            address(tokenA), // tokenIn != USDC
            amountInTokenA,
            1_000e6, // minUsdcOut (we demand 1000 USDC)
            block.timestamp + 1,
            bytes(""), // routerCommands dummy
            new bytes[](0) // routerInputs dummy
        );
        vm.stopPrank();
    }

    // ========= Withdrawals =========

    function test_Withdraw() public {
        uint256 depositAmount = 5_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), depositAmount);
        bank.depositArbitraryToken(
            address(usdc),
            depositAmount,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0)
        );

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
            bytes(""),
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
            bytes(""),
            new bytes[](0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBank.InsufficientBalance.selector,
                2_000e6,
                1_000e6
            )
        );
        bank.withdrawUsdc(2_000e6);
        vm.stopPrank();
    }

    // ========= Bank Cap =========

    function test_BankCap_WithinLimit() public {
        uint256 amount = 500_000e6; // 500k USDC, < 1M cap

        vm.startPrank(user1);
        usdc.approve(address(bank), amount);
        bank.depositArbitraryToken(
            address(usdc),
            amount,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0)
        );
        vm.stopPrank();

        assertEq(bank.totalUsdcInVault(), amount);
        assertEq(bank.remainingCapacityUsdc(), BANK_CAP - amount);
    }

    function test_BankCap_Exceed() public {
        uint256 firstDeposit = 500_000e6;
        uint256 secondDeposit = 501_000e6; // 500k + 501k = 1.001M > 1M

        vm.startPrank(user1);
        usdc.approve(address(bank), firstDeposit + secondDeposit);

        // First deposit stays under cap
        bank.depositArbitraryToken(
            address(usdc),
            firstDeposit,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0)
        );

        // Second deposit should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                KipuBank.BankCapacityExceeded.selector,
                firstDeposit,
                secondDeposit,
                BANK_CAP
            )
        );
        bank.depositArbitraryToken(
            address(usdc),
            secondDeposit,
            0,
            block.timestamp + 1,
            bytes(""),
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
            bytes(""),
            new bytes[](0)
        );

        uint256 remainingBefore = bank.remainingCapacityUsdc();

        bank.withdrawUsdc(100e6);

        assertEq(bank.remainingCapacityUsdc(), remainingBefore + 100e6);
        vm.stopPrank();
    }

    // ========= Admin Functions =========

    function test_RecoverFunds() public {
        // user deposits first (nonzero balance)
        vm.startPrank(user1);
        usdc.approve(address(bank), 1_000e6);
        bank.depositArbitraryToken(
            address(usdc),
            1_000e6,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0)
        );
        vm.stopPrank();

        // admin corrects the balance
        vm.prank(admin);
        bank.recoverFunds(user1, 10_000e6);

        assertEq(bank.balanceOfUsdc(user1), 10_000e6);
    }

    function test_RecoverFunds_NotManager() public {
        vm.startPrank(user1);
        vm.expectRevert(); // AccessControl revert (not MANAGER_ROLE)
        bank.recoverFunds(user2, 1_000e6);
        vm.stopPrank();
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
            bytes(""),
            new bytes[](0)
        );
        vm.stopPrank();
    }

    function test_Event_WithdrawnUSDC() public {
        uint256 depositAmt = 7_000e6;
        uint256 withdrawAmt = 2_000e6;

        vm.startPrank(user1);
        usdc.approve(address(bank), depositAmt);
        bank.depositArbitraryToken(
            address(usdc),
            depositAmt,
            0,
            block.timestamp + 1,
            bytes(""),
            new bytes[](0)
        );

        vm.expectEmit(true, false, false, true);
        emit KipuBank.WithdrawnUSDC(user1, withdrawAmt);

        bank.withdrawUsdc(withdrawAmt);
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
            bytes(""),
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

        vm.startPrank(user1);
        vm.expectRevert(KipuBank.DirectEthTransferNotAllowed.selector);
        (bool ok, ) = address(bank).call{value: 1 ether}("");
        ok; // silence warning
        vm.stopPrank();
    }
}
