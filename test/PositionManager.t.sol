// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { IERC20Indexable } from "../contracts/Interfaces/IERC20Indexable.sol";
import { IPositionManager } from "../contracts/Interfaces/IPositionManager.sol";
import { PositionManager } from "../contracts/PositionManager.sol";
import { MathUtils } from "../contracts/Dependencies/MathUtils.sol";
import { PriceFeedTestnet } from "./mocks/PriceFeedTestnet.sol";
import { PositionManagerUtils } from "./utils/PositionManagerUtils.sol";
import { SplitLiquidationCollateral } from "../contracts/SplitLiquidationCollateral.sol";
import { TestSetup } from "./utils/TestSetup.t.sol";

contract PositionManagerTest is TestSetup {
    PriceFeedTestnet public priceFeed;

    function setUp() public override {
        super.setUp();

        priceFeed = new PriceFeedTestnet();
        priceFeed.setPrice(1e18);
        positionManager.addCollateralToken(collateralToken, priceFeed);

        collateralToken.mint(ALICE, 10e36);
        collateralToken.mint(BOB, 10e36);
    }

    // --- Delegates ---

    function testDelegateWhitelist() public {
        vm.startPrank(ALICE);
        PositionManagerUtils.openPosition({
            positionManager: positionManager,
            priceFeed: priceFeed,
            collateralToken: collateralToken,
            position: ALICE,
            icr: 2e18
        });
        vm.stopPrank();

        vm.prank(ALICE);
        positionManager.whitelistDelegate(BOB, true);
        assertTrue(positionManager.isDelegateWhitelisted(ALICE, BOB));
        uint256 collateralTopUpAmount = 1 ether;
        vm.startPrank(BOB);
        collateralToken.approve(address(positionManager), collateralTopUpAmount);
        positionManager.managePosition(
            collateralToken, ALICE, collateralTopUpAmount, true, 0, false, 0, emptySignature
        );
        vm.stopPrank();
        vm.prank(ALICE);
        positionManager.whitelistDelegate(BOB, false);
        assertFalse(positionManager.isDelegateWhitelisted(ALICE, BOB));
    }

    function testNonDelegateCannotManagePosition() public {
        uint256 collateralTopUpAmount = 1 ether;
        vm.startPrank(BOB);
        collateralToken.approve(address(positionManager), collateralTopUpAmount);

        vm.expectRevert(IPositionManager.DelegateNotWhitelisted.selector);
        positionManager.managePosition(
            collateralToken, ALICE, collateralTopUpAmount, true, 0, false, 0, emptySignature
        );
    }

    function testIndividualDelegateCannotManageOtherPositions() public {
        vm.startPrank(ALICE);
        PositionManagerUtils.openPosition({
            positionManager: positionManager,
            priceFeed: priceFeed,
            collateralToken: collateralToken,
            position: ALICE,
            icr: 2e18
        });
        vm.stopPrank();

        vm.prank(CAROL);
        positionManager.whitelistDelegate(BOB, true);

        uint256 collateralTopUpAmount = 1 ether;
        vm.prank(ALICE);
        collateralToken.approve(address(positionManager), collateralTopUpAmount);

        vm.prank(BOB);
        vm.expectRevert(IPositionManager.DelegateNotWhitelisted.selector);
        positionManager.managePosition(
            collateralToken, ALICE, collateralTopUpAmount, true, 0, false, 0, emptySignature
        );
    }

    // --- Borrowing Spread ---

    function testSetBorrowingSpread() public {
        positionManager.setBorrowingSpread(100);
        assertEq(positionManager.borrowingSpread(), 100);
    }

    function testUnauthorizedSetBorrowingSpread() public {
        vm.prank(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");

        positionManager.setBorrowingSpread(100);
    }

    function testOutOfRangeSetBorrowingSpread() public {
        uint256 maxBorrowingSpread = positionManager.MAX_BORROWING_SPREAD();
        vm.expectRevert(IPositionManager.BorrowingSpreadExceedsMaximum.selector);
        positionManager.setBorrowingSpread(maxBorrowingSpread + 1);
    }

    function testOutOfRangeSetRedemptionRebate() public {
        vm.expectRevert(IPositionManager.RedemptionRebateExceedsMaximum.selector);
        positionManager.setRedemptionRebate(1e18 + 1);
    }

    // --- Redemption Spread ---

    function testSetRedemptionSpread() public {
        uint256 spread = positionManager.MIN_REDEMPTION_SPREAD() + 1;
        positionManager.setRedemptionSpread(spread);
        assertEq(positionManager.redemptionSpread(), spread);
    }

    function testUnauthorizedSetRedemptionSpread() public {
        vm.prank(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");

        positionManager.setRedemptionSpread(100);
    }

    function testOutOfRangeSetRedemptionSpread() public {
        uint256 minRedemptionSpread = positionManager.MIN_REDEMPTION_SPREAD();
        vm.expectRevert(IPositionManager.RedemptionSpreadOutOfRange.selector);
        positionManager.setRedemptionSpread(minRedemptionSpread - 1);

        uint256 maxRedemptionSpread = positionManager.MAX_REDEMPTION_SPREAD();
        vm.expectRevert(IPositionManager.RedemptionSpreadOutOfRange.selector);
        positionManager.setRedemptionSpread(maxRedemptionSpread + 1);
    }

    // --- Split liquidation collateral ---
    function testSetSplitLiquidationCollateral() public {
        SplitLiquidationCollateral newSplitLiquidationCollateral = new SplitLiquidationCollateral();

        positionManager.setSplitLiquidationCollateral(newSplitLiquidationCollateral);
        assertEq(address(positionManager.splitLiquidationCollateral()), address(newSplitLiquidationCollateral));
    }

    function testCannotSetSplitLiquidationCollateral() public {
        vm.expectRevert(IPositionManager.SplitLiquidationCollateralCannotBeZero.selector);
        positionManager.setSplitLiquidationCollateral(SplitLiquidationCollateral(address(0)));

        SplitLiquidationCollateral newSplitLiquidationCollateral = new SplitLiquidationCollateral();
        vm.prank(ALICE);
        vm.expectRevert("Ownable: caller is not the owner");

        positionManager.setSplitLiquidationCollateral(newSplitLiquidationCollateral);
    }

    // --- Getters ---

    // Returns collateral
    function testGetPositionCollateral() public {
        vm.startPrank(ALICE);
        PositionManagerUtils.OpenPositionResult memory alicePosition = PositionManagerUtils.openPosition({
            positionManager: positionManager,
            priceFeed: priceFeed,
            collateralToken: collateralToken,
            position: ALICE,
            icr: 150 * MathUtils._100_PERCENT / 100
        });
        vm.stopPrank();

        vm.startPrank(BOB);
        PositionManagerUtils.OpenPositionResult memory bobPosition = PositionManagerUtils.openPosition({
            positionManager: positionManager,
            priceFeed: priceFeed,
            collateralToken: collateralToken,
            position: BOB,
            icr: 150 * MathUtils._100_PERCENT / 100
        });
        vm.stopPrank();

        (IERC20Indexable raftCollateralToken,) = positionManager.raftCollateralTokens(collateralToken);

        assertEq(raftCollateralToken.balanceOf(ALICE), alicePosition.collateral);
        assertEq(raftCollateralToken.balanceOf(BOB), bobPosition.collateral);
    }

    // Returns debt
    function testGetPositionDebt() public {
        vm.startPrank(ALICE);
        PositionManagerUtils.OpenPositionResult memory alicePosition = PositionManagerUtils.openPosition({
            positionManager: positionManager,
            priceFeed: priceFeed,
            collateralToken: collateralToken,
            position: ALICE,
            icr: 150 * MathUtils._100_PERCENT / 100
        });
        vm.stopPrank();

        vm.startPrank(BOB);
        PositionManagerUtils.OpenPositionResult memory bobPosition = PositionManagerUtils.openPosition({
            positionManager: positionManager,
            priceFeed: priceFeed,
            collateralToken: collateralToken,
            position: BOB,
            icr: 150 * MathUtils._100_PERCENT / 100
        });
        vm.stopPrank();

        assertEq(positionManager.raftDebtToken().balanceOf(ALICE), alicePosition.totalDebt);
        assertEq(positionManager.raftDebtToken().balanceOf(BOB), bobPosition.totalDebt);
    }
}
