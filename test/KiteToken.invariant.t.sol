// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {KiteToken} from "../src/KiteToken.sol";

/// @notice Stands in for the launch factory: a contract whose constructor deploys the token, so the
/// token's `msg.sender` is a contract address holding the whole supply, as it will be at launch.
contract FactoryProbe {
    KiteToken public immutable token;

    constructor() {
        token = new KiteToken();
    }
}

/// @notice Drives the token with random, bounded calls from a small set of actors and keeps a ghost
/// ledger of what every actor should hold and what every allowance should be.
/// @dev Every token call is wrapped in try/catch, so the handler itself never reverts: an outcome that
/// disagrees with the expectation (a call that should succeed reverting, a call that should revert
/// succeeding, or a revert with the wrong error) is recorded in `violations` and reported by an
/// invariant, with the first message kept for the failing sequence.
contract KiteHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    KiteToken public immutable token;
    address public immutable factory;
    address[] public actors;

    // ---- ghost ledger
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    // ---- expectation tracking
    uint256 public violations;
    string public firstViolation;

    // ---- call counters, so a run that exercised nothing is visible in the summary
    uint256 public countTransfer;
    uint256 public countTransferAboveBalance;
    uint256 public countTransferToZero;
    uint256 public countApprove;
    uint256 public countApproveUnlimited;
    uint256 public countApproveZeroSpender;
    uint256 public countTransferFrom;
    uint256 public countTransferFromUnlimited;
    uint256 public countTransferFromAboveAllowance;
    uint256 public countTransferFromAboveBalance;
    uint256 public countAdminProbe;
    uint256 public countEtherProbe;

    constructor() {
        FactoryProbe probe = new FactoryProbe();
        token = probe.token();
        factory = address(probe);
        actors.push(factory);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(makeAddr("erin"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ happy paths

    /// @dev A transfer within the sender's balance must succeed, return true and move exactly `amount`.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) _violate("transfer returned false");
            ghostSent[from] += amount;
            ghostReceived[to] += amount;
        } catch {
            _violate("transfer within balance reverted");
        }
        countTransfer++;
    }

    /// @dev Sets an allowance; one call in four sets the unlimited sentinel, the rest a finite value that
    /// may exceed the supply (finite allowances above the supply must still be decremented, not treated
    /// as unlimited).
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint256 mode) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        mode = bound(mode, 0, 3);
        if (mode == 0) {
            amount = type(uint256).max;
            countApproveUnlimited++;
        } else if (mode == 1) {
            amount = bound(amount, SUPPLY + 1, type(uint256).max - 1);
        } else {
            amount = bound(amount, 0, SUPPLY);
        }

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) _violate("approve returned false");
            ghostAllowance[owner][spender] = amount;
        } catch {
            _violate("approve of a non-zero spender reverted");
        }
        countApprove++;
    }

    /// @dev A transferFrom within both the owner's balance and the spender's allowance must succeed,
    /// move exactly `amount`, and decrement the allowance unless it is unlimited. When the pair has no
    /// allowance yet the owner grants one first (unlimited one time in three), so the spending path is
    /// reached often rather than only when an earlier random approve happened to pick the same pair.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount, uint256 grant)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        if (token.allowance(owner, spender) == 0) {
            grant = bound(grant, 0, 2);
            uint256 granted = grant == 0 ? type(uint256).max : bound(amount, grant == 1 ? 0 : balance, SUPPLY);
            vm.prank(owner);
            try token.approve(spender, granted) {
                ghostAllowance[owner][spender] = granted;
            } catch {
                _violate("approve before transferFrom reverted");
                return;
            }
        }
        uint256 allowed = token.allowance(owner, spender);
        bool unlimited = allowed == type(uint256).max;
        uint256 cap = unlimited || allowed > balance ? balance : allowed;
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) _violate("transferFrom returned false");
            ghostSent[owner] += amount;
            ghostReceived[to] += amount;
            if (!unlimited) ghostAllowance[owner][spender] = allowed - amount;
        } catch {
            _violate("transferFrom within balance and allowance reverted");
        }
        if (unlimited) countTransferFromUnlimited++;
        countTransferFrom++;
    }

    // ------------------------------------------------------------------ failure paths

    /// @dev A transfer of more than the sender holds must revert with InsufficientBalance and move nothing.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        uint256 amount = balance + bound(excess, 1, SUPPLY);

        vm.prank(from);
        try token.transfer(to, amount) {
            _violate("transfer above balance succeeded");
        } catch (bytes memory err) {
            _expectError(
                err,
                abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, from, balance, amount),
                "transfer above balance"
            );
        }
        countTransferAboveBalance++;
    }

    /// @dev Nothing may be sent to the zero address, not even zero.
    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        try token.transfer(address(0), amount) {
            _violate("transfer to the zero address succeeded");
        } catch (bytes memory err) {
            _expectError(
                err, abi.encodeWithSelector(KiteToken.InvalidReceiver.selector, address(0)), "transfer to zero"
            );
        }
        countTransferToZero++;
    }

    /// @dev The zero address may not be approved, so no allowance can ever be read for it.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);

        vm.prank(owner);
        try token.approve(address(0), amount) {
            _violate("approve of the zero spender succeeded");
        } catch (bytes memory err) {
            _expectError(
                err, abi.encodeWithSelector(KiteToken.InvalidSpender.selector, address(0)), "approve zero spender"
            );
        }
        countApproveZeroSpender++;
    }

    /// @dev A transferFrom beyond a finite allowance must revert with InsufficientAllowance, whatever the
    /// owner's balance, and leave the allowance untouched.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return; // nothing is above an unlimited allowance
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            _violate("transferFrom above allowance succeeded");
        } catch (bytes memory err) {
            _expectError(
                err,
                abi.encodeWithSelector(KiteToken.InsufficientAllowance.selector, spender, allowed, amount),
                "transferFrom above allowance"
            );
        }
        countTransferFromAboveAllowance++;
    }

    /// @dev With allowance in hand but the owner short of funds, transferFrom must revert with
    /// InsufficientBalance and the whole call, allowance decrement included, must roll back.
    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 amount = balance + bound(excess, 1, SUPPLY);

        vm.prank(owner);
        try token.approve(spender, amount) {
            ghostAllowance[owner][spender] = amount;
        } catch {
            _violate("approve before transferFrom above balance reverted");
            return;
        }

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            _violate("transferFrom above balance succeeded");
        } catch (bytes memory err) {
            _expectError(
                err,
                abi.encodeWithSelector(KiteToken.InsufficientBalance.selector, owner, balance, amount),
                "transferFrom above balance"
            );
        }
        countTransferFromAboveBalance++;
    }

    /// @dev Any actor, the factory included, tries one of the usual admin entry points. None exist, so
    /// the call must fail; the ledger invariants then confirm nothing moved.
    function probeAdminSurface(uint256 callerSeed, uint256 targetSeed, uint256 which) external {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        string memory signature = signatures[bound(which, 0, signatures.length - 1)];
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(signature, target, SUPPLY));
        if (ok) _violate(string.concat("admin selector accepted: ", signature));
        countAdminProbe++;
    }

    /// @dev The token has no receive or fallback: ether and unknown calldata are both refused.
    function probeEther(uint256 callerSeed, uint256 value) external {
        address caller = _actor(callerSeed);
        value = bound(value, 1, 100 ether);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}("");
        if (ok) _violate("token accepted ether");
        countEtherProbe++;
    }

    // ------------------------------------------------------------------ helpers

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _violate(string memory reason) private {
        if (violations == 0) firstViolation = reason;
        violations++;
    }

    function _expectError(bytes memory actual, bytes memory expected, string memory context) private {
        if (keccak256(actual) != keccak256(expected)) _violate(string.concat(context, ": wrong revert data"));
    }
}

/// @notice Invariants the token must keep across any sequence of handler calls.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract KiteTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    KiteHandler handler;
    KiteToken token;

    function setUp() public {
        handler = new KiteHandler();
        token = handler.token();
        targetContract(address(handler));
    }

    /// @dev Every expectation the handler checked on its own calls held: calls within limits succeeded,
    /// calls beyond them reverted with exactly the typed error the contract documents.
    function invariant_handlerExpectationsHeld() public view {
        assertEq(handler.violations(), 0, handler.firstViolation());
    }

    /// @dev Fixed supply: no sequence changes what totalSupply() reports.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev Conservation: every token minted is held by exactly one of the actors (the only addresses the
    /// handler ever sends to), and none has leaked to the zero address or the token itself.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "sum of actor balances != supply");
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "token holds itself");
    }

    /// @dev Per-actor accounting: a balance is exactly what the actor started with, plus everything it
    /// was sent, minus everything it sent, so no transfer path moves more or less than it says.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            uint256 start = actor == handler.factory() ? SUPPLY : 0;
            assertEq(
                token.balanceOf(actor),
                start + handler.ghostReceived(actor) - handler.ghostSent(actor),
                "balance disagrees with ghost ledger"
            );
        }
    }

    /// @dev No single holder can hold more than exists.
    function invariant_noBalanceExceedsSupply() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.actors(i)), SUPPLY);
        }
    }

    /// @dev Allowances are exactly what the owner last approved, less what finite allowances have spent;
    /// an unlimited allowance stays unlimited; nothing but approve and a successful transferFrom touches
    /// them, and transfers never do.
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
            assertEq(token.allowance(owner, address(0)), 0, "zero spender has an allowance");
        }
    }

    /// @dev The token never holds ether: it has no payable path.
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0);
    }

    /// @dev Metadata is compile-time constant and cannot drift under any call sequence.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Kite");
        assertEq(token.symbol(), "KITE");
        assertEq(token.decimals(), 18);
    }

    /// @dev Printed after each run (visible with -vv) so an empty run cannot pass unnoticed.
    function afterInvariant() public view {
        console2.log(
            "transfer / aboveBalance / toZero",
            handler.countTransfer(),
            handler.countTransferAboveBalance(),
            handler.countTransferToZero()
        );
        console2.log(
            "approve / unlimited / zeroSpender",
            handler.countApprove(),
            handler.countApproveUnlimited(),
            handler.countApproveZeroSpender()
        );
        console2.log("transferFrom / unlimited", handler.countTransferFrom(), handler.countTransferFromUnlimited());
        console2.log(
            "transferFrom aboveAllowance / aboveBalance",
            handler.countTransferFromAboveAllowance(),
            handler.countTransferFromAboveBalance()
        );
        console2.log("admin probes / ether probes", handler.countAdminProbe(), handler.countEtherProbe());
    }
}
