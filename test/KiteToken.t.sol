// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KiteToken} from "../src/KiteToken.sol";

/// @notice Stands in for the launch factory: deploys the token so the constructor's `msg.sender` is a
/// contract, exactly as it will be at launch, and holds the supply.
contract DeployerProbe {
    KiteToken public token;

    function deploy() external returns (KiteToken) {
        token = new KiteToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract KiteTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    DeployerProbe deployer;
    KiteToken token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        deployer = new DeployerProbe();
        token = deployer.deploy();
    }

    // ---------------------------------------------------------------- construction & metadata

    function test_metadata() public view {
        assertEq(token.name(), "Kite");
        assertEq(token.symbol(), "KITE");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(deployer)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        DeployerProbe fresh = new DeployerProbe();
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(fresh), SUPPLY);
        fresh.deploy();
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }

    // ---------------------------------------------------------------- transfer

    function test_transferMovesExactAmount() public {
        assertTrue(deployer.send(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(address(deployer)), SUPPLY - 1_000 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 400 ether);
        assertTrue(token.transfer(bob, 400 ether));

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalanceLeavesZero() public {
        deployer.send(alice, 5 ether);
        vm.prank(alice);
        token.transfer(bob, 5 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 5 ether);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        deployer.send(alice, 7 ether);
        vm.prank(alice);
        token.transfer(alice, 7 ether);
        assertEq(token.balanceOf(alice), 7 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        deployer.send(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, alice, 10 ether, 10 ether + 1));
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, carol, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 123);
        assertTrue(token.approve(bob, 123));
        assertEq(token.allowance(alice, bob), 123);
    }

    function test_approveOverwritesRatherThanAdds() public {
        vm.startPrank(alice);
        token.approve(bob, 100);
        token.approve(bob, 40);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 40);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        deployer.send(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 60 ether);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, carol, 50 ether);
        assertTrue(token.transferFrom(alice, carol, 50 ether));

        assertEq(token.balanceOf(alice), 50 ether);
        assertEq(token.balanceOf(carol), 50 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, bob), 10 ether);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        deployer.send(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 30 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), 30 ether);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        deployer.send(alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        deployer.send(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, bob, 10 ether, 10 ether + 1));
        token.transferFrom(alice, carol, 10 ether + 1);
        assertEq(token.allowance(alice, bob), 10 ether);
    }

    function test_transferFromRevertsBeyondBalanceEvenWithAllowance() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 5 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, alice, 1 ether, 2 ether));
        token.transferFrom(alice, carol, 2 ether);
    }

    function test_transferFromRevertsToZeroAddress() public {
        deployer.send(alice, 1 ether);
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1 ether);
    }

    function test_transferFromCannotMoveAHolderWithoutApprovalEvenForDeployer() public {
        deployer.send(alice, 1 ether);
        vm.prank(address(deployer));
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, address(deployer), 0, 1));
        token.transferFrom(alice, address(deployer), 1);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    // ---------------------------------------------------------------- no privileged surface

    /// @dev None of the usual supply-growing or admin entry points exist: every call falls through to
    /// the missing-function path and reverts, from a stranger and from the deployer alike.
    function test_noSupplyGrowingOrAdminFunctions() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(deployer));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @dev Nothing can pause, block, freeze, lock or seize: every such call reverts, and afterwards the
    /// holder still holds and can still transfer.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        deployer.send(alice, SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(address(deployer));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(alice), held);
        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
    }

    function test_rejectsPlainEtherAndUnknownCalldata() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "accepted ether");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "accepted unknown selector");
    }

    // ---------------------------------------------------------------- bytecode properties

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_contractNameFitsTheManifest() public pure {
        bytes memory contractName = bytes("KiteToken");
        assertLe(contractName.length, 32);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(deployer));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(deployer.send(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(deployer)) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        deployer.send(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, 0, SUPPLY);
        deployer.send(alice, SUPPLY);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        if (amount > allowed) {
            vm.expectRevert(abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, bob, allowed, amount));
            token.transferFrom(alice, carol, amount);
        } else {
            assertTrue(token.transferFrom(alice, carol, amount));
            assertEq(token.allowance(alice, bob), allowed - amount);
            assertEq(token.balanceOf(carol), amount);
        }
    }
}
