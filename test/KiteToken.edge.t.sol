// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {KiteToken} from "../src/KiteToken.sol";

/// @notice Deploys the token from a contract, as the launch factory will, and holds the supply.
contract FactoryStandIn {
    KiteToken public immutable token;

    constructor() {
        token = new KiteToken();
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Edge inputs and launch-shaped flows the unit suite in KiteToken.t.sol does not pin: the zero
/// sender, the exact allowance boundary, finite allowances above the supply, the unlimited sentinel's
/// event behaviour, self-dealing approvals, independent deployments, and multi-hop launch flows.
/// forge-config: default.fuzz.runs = 1000
contract KiteTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant MAX = type(uint256).max;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    FactoryStandIn factory;
    KiteToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        factory = new FactoryStandIn();
        token = factory.token();
    }

    // ---------------------------------------------------------------- deployment

    /// @dev Whoever runs the constructor holds everything: an externally owned deployer too, not only a contract.
    function test_eoaDeployerReceivesWholeSupply() public {
        address eoa = makeAddr("eoa");
        vm.prank(eoa);
        KiteToken fresh = new KiteToken();
        assertEq(fresh.balanceOf(eoa), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    /// @dev Each deployment is its own ledger: a second token does not share balances with the first.
    function test_independentDeploymentsDoNotShareState() public {
        FactoryStandIn second = new FactoryStandIn();
        KiteToken other = second.token();
        assertEq(other.balanceOf(address(second)), SUPPLY);
        assertEq(other.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(second)), 0);

        factory.send(alice, 1 ether);
        assertEq(other.balanceOf(alice), 0);
    }

    /// @dev The constructor emits exactly one event: the mint. Nothing else is logged at deployment.
    function test_constructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        new KiteToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(this));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    /// @dev The supply fits comfortably in the 128-bit signed deltas the Uniswap v4 pool manager uses and
    /// in a uint96, so no launch flow can overflow a narrower accumulator downstream.
    function test_supplyFitsNarrowDownstreamTypes() public view {
        assertLe(token.totalSupply(), uint256(uint128(type(int128).max)));
        assertLe(token.totalSupply(), type(uint96).max);
    }

    // ---------------------------------------------------------------- zero sender

    function test_transferFromZeroSenderRevertsInvalidSender() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InvalidSender.selector, address(0)));
        token.transfer(alice, 0);
    }

    function test_approveFromZeroOwnerRevertsInvalidSender() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InvalidSender.selector, address(0)));
        token.approve(alice, 1);
    }

    /// @dev `from == address(0)` with a zero amount passes the allowance check (0 <= 0) and must still be
    /// refused by the transfer itself: no event-emitting path exists from the zero address.
    function test_transferFromWithZeroOwnerRevertsInvalidSender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InvalidSender.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
    }

    /// @dev With a non-zero amount the allowance check fires first: nobody is allowed to spend from zero.
    function test_transferFromWithZeroOwnerAndAmountRevertsOnAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    // ---------------------------------------------------------------- balance boundaries

    function test_transferWholeSupplyAndBack() public {
        assertTrue(factory.send(alice, SUPPLY));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        vm.prank(alice);
        token.transfer(address(factory), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferOneWeiMoreThanSupplyReverts() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_transferMaxUintReverts() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, address(factory), SUPPLY, MAX));
        token.transfer(alice, MAX);
    }

    /// @dev A failed transfer is atomic: nothing moved and no event was emitted.
    function test_failedTransferLeavesNoTrace() public {
        factory.send(alice, 3);
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(KiteToken.transfer, (bob, 4)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.balanceOf(alice), 3);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToTokenContractIsAllowedButStranded() public {
        // ERC-20 does not forbid sending to the token itself; the tokens are simply unrecoverable, since
        // the contract has no function that moves its own balance. Recorded here as documented behaviour.
        factory.send(address(token), 1);
        assertEq(token.balanceOf(address(token)), 1);
        vm.prank(address(token));
        assertTrue(token.transfer(alice, 1)); // only the token itself could, and nothing makes it call
    }

    // ---------------------------------------------------------------- allowance boundaries

    function test_transferFromExactAllowanceLeavesZeroAndNextWeiReverts() public {
        factory.send(alice, 10);
        vm.prank(alice);
        token.approve(bob, 10);

        vm.prank(bob);
        token.transferFrom(alice, carol, 10);
        assertEq(token.allowance(alice, bob), 0);

        factory.send(alice, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    /// @dev Only the exact maximum is unlimited: one less is a finite allowance and is decremented.
    function test_allowanceMaxMinusOneIsFiniteAndDecremented() public {
        factory.send(alice, 5);
        vm.prank(alice);
        token.approve(bob, MAX - 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 5);
        assertEq(token.allowance(alice, bob), MAX - 6);
    }

    /// @dev A finite allowance above the whole supply is decremented like any other.
    function test_allowanceAboveSupplyIsDecremented() public {
        factory.send(alice, 7);
        vm.prank(alice);
        token.approve(bob, SUPPLY + 1);
        vm.prank(bob);
        token.transferFrom(alice, carol, 7);
        assertEq(token.allowance(alice, bob), SUPPLY + 1 - 7);
    }

    /// @dev An unlimited allowance emits no Approval on spend: the only log is the Transfer.
    function test_unlimitedAllowanceSpendEmitsOnlyTransfer() public {
        factory.send(alice, 9);
        vm.prank(alice);
        token.approve(bob, MAX);

        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 9);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(token.allowance(alice, bob), MAX);
    }

    /// @dev A finite allowance spend emits Approval with the remaining allowance, then Transfer.
    function test_finiteAllowanceSpendEmitsApprovalThenTransfer() public {
        factory.send(alice, 9);
        vm.prank(alice);
        token.approve(bob, 20);

        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 9);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], keccak256("Approval(address,address,uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), 11);
        assertEq(logs[1].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(abi.decode(logs[1].data, (uint256)), 9);
    }

    /// @dev Zero-amount transferFrom with zero allowance is permitted by the standard (0 <= 0) and moves nothing.
    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 0);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 0);
        assertTrue(token.transferFrom(alice, carol, 0));
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_approveSelfAndSpendOwnAllowance() public {
        factory.send(alice, 4);
        vm.startPrank(alice);
        token.approve(alice, 3);
        token.transferFrom(alice, bob, 3);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 3);
    }

    function test_transferFromToSelfKeepsBalanceButSpendsAllowance() public {
        factory.send(alice, 4);
        vm.prank(alice);
        token.approve(bob, 4);
        vm.prank(bob);
        token.transferFrom(alice, alice, 4);
        assertEq(token.balanceOf(alice), 4);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_spenderCanPullToItself() public {
        factory.send(alice, 4);
        vm.prank(alice);
        token.approve(bob, 4);
        vm.prank(bob);
        token.transferFrom(alice, bob, 4);
        assertEq(token.balanceOf(bob), 4);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Allowances are directional and per-spender: granting bob says nothing about carol, or about
    /// what bob lets alice spend.
    function test_allowanceIsDirectionalAndPerSpender() public {
        factory.send(alice, 4);
        vm.prank(alice);
        token.approve(bob, 4);
        assertEq(token.allowance(bob, alice), 0);
        assertEq(token.allowance(alice, carol), 0);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    /// @dev Moving tokens by plain transfer never touches allowances in either direction.
    function test_transferDoesNotTouchAllowances() public {
        factory.send(alice, 4);
        vm.startPrank(alice);
        token.approve(bob, 2);
        token.transfer(bob, 4);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 2);
        assertEq(token.allowance(bob, alice), 0);
    }

    /// @dev The owner can revoke: approve(spender, 0) ends the spender's access immediately.
    function test_revokeAllowanceStopsSpender() public {
        factory.send(alice, 4);
        vm.startPrank(alice);
        token.approve(bob, MAX);
        token.approve(bob, 0);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
    }

    /// @dev A failed transferFrom rolls the allowance decrement back along with the balance move.
    function test_failedTransferFromRollsBackAllowance() public {
        factory.send(alice, 1);
        vm.prank(alice);
        token.approve(bob, 5);
        vm.prank(bob);
        (bool ok,) = address(token).call(abi.encodeCall(KiteToken.transferFrom, (alice, carol, 2)));
        assertFalse(ok);
        assertEq(token.allowance(alice, bob), 5);
        assertEq(token.balanceOf(alice), 1);
    }

    // ---------------------------------------------------------------- launch-shaped flows

    /// @dev The launch split as the factory performs it: ten percent to the distributor, then claims out
    /// of it; the pool share and the remainder out of the factory. Every leg arrives whole and the
    /// factory ends at exactly zero.
    function testFuzz_launchSplitArrivesWhole(uint256 poolBps, uint256 claimants) public {
        poolBps = bound(poolBps, 0, 9_000);
        claimants = bound(claimants, 1, 20);
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address requester = makeAddr("requester");

        uint256 swarm = SUPPLY * 1_000 / 10_000;
        uint256 poolShare = SUPPLY * poolBps / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;

        assertTrue(factory.send(distributor, swarm));
        assertTrue(factory.send(pool, poolShare));
        assertTrue(factory.send(requester, remainder));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(requester), remainder);

        uint256 each = swarm / claimants;
        uint256 paid;
        for (uint256 i; i < claimants; ++i) {
            address claimant = address(uint160(0xC1A1_0000 + i));
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, each));
            assertEq(token.balanceOf(claimant), each);
            paid += each;
        }
        assertEq(token.balanceOf(distributor), swarm - paid);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev An amount pushed through any number of hops arrives unchanged at the end: no fee, tax or
    /// rounding on any leg.
    function testFuzz_multiHopDeliversExactAmount(uint256 amount, uint8 hops) public {
        amount = bound(amount, 0, SUPPLY);
        hops = uint8(bound(hops, 1, 16));
        address previous = address(factory);
        for (uint256 i; i < hops; ++i) {
            address next = address(uint160(0x4040_0000 + i));
            vm.prank(previous);
            assertTrue(token.transfer(next, amount));
            assertEq(token.balanceOf(previous), previous == address(factory) ? SUPPLY - amount : 0);
            assertEq(token.balanceOf(next), amount);
            previous = next;
        }
        assertEq(token.balanceOf(previous) + token.balanceOf(address(factory)), SUPPLY);
    }

    /// @dev A pool-style pull: the holder approves exactly the amount, the pool pulls it with
    /// transferFrom, and the allowance is consumed exactly, so a second pull of one wei fails.
    function testFuzz_pullPaymentConsumesExactAllowance(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY - 1); // one wei stays with the factory for the follow-up top-up
        address pool = makeAddr("pool");
        factory.send(alice, amount);
        vm.prank(alice);
        token.approve(pool, amount);
        vm.prank(pool);
        assertTrue(token.transferFrom(alice, pool, amount));
        assertEq(token.balanceOf(pool), amount);
        assertEq(token.allowance(alice, pool), 0);
        factory.send(alice, 1);
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, pool, 0, 1));
        token.transferFrom(alice, pool, 1);
    }

    // ---------------------------------------------------------------- property fuzz

    /// @dev approve then allowance is a round trip for every value, the sentinel included.
    function testFuzz_approveAllowanceRoundTrip(address spender, uint256 amount) public {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
    }

    /// @dev Sending and sending back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount, uint256 back) public {
        amount = bound(amount, 0, SUPPLY);
        back = bound(back, 0, amount);
        factory.send(alice, amount);
        vm.prank(alice);
        token.transfer(address(factory), back);
        assertEq(token.balanceOf(alice), amount - back);
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount + back);
    }

    /// @dev Splitting a balance in two sends across the same recipient equals sending it once.
    function testFuzz_transferIsAdditive(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        factory.send(alice, total);
        vm.startPrank(alice);
        token.transfer(bob, first);
        token.transfer(bob, total - first);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), total);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev The revert data on a failed transfer reports the sender's true balance and the request.
    function testFuzz_insufficientBalanceErrorIsAccurate(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, MAX - held);
        factory.send(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, alice, held, held + excess));
        token.transfer(bob, held + excess);
    }

    /// @dev Only the sentinel is unlimited: every other allowance, however large, is decremented.
    function testFuzz_onlyMaxAllowanceIsUnlimited(uint256 allowed, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        allowed = bound(allowed, amount, MAX);
        factory.send(alice, amount);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        token.transferFrom(alice, carol, amount);
        assertEq(token.allowance(alice, bob), allowed == MAX ? MAX : allowed - amount);
        assertEq(token.balanceOf(carol), amount);
    }

    /// @dev Any address but zero may receive, including precompiles and contracts, and the amount
    /// arrives whole.
    function testFuzz_anyNonZeroRecipientReceivesWhole(address to, uint256 amount) public {
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);
        uint256 factoryBefore = token.balanceOf(address(factory));
        assertTrue(factory.send(to, amount));
        if (to == address(factory)) {
            assertEq(token.balanceOf(to), before);
        } else {
            assertEq(token.balanceOf(to), before + amount);
            assertEq(token.balanceOf(address(factory)), factoryBefore - amount);
        }
    }
}
