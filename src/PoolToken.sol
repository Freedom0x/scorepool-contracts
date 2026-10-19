// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VenueGate} from "./VenueGate.sol";

/// @notice The contracts the POOL/ETH pool hook is wired to (PoolHookBase), and PoolLaunch's launcher.
interface IHookWiring {
    function gate() external view returns (address);
    function burner() external view returns (address);
    function builder() external view returns (address);
}

interface ILauncherOf {
    function launcher() external view returns (address);
}

/// @title PoolToken
/// @notice POOL (Credit Pool), the fixed-supply, burnable protocol token. The whole supply is minted once, to the
/// distributor that seeds the pool and funds the farm; there is no further minting. The trading tax is in the
/// pool's hook.
/// @dev Trading is kept in the POOL/ETH pool (see VenueGate). The deployer sets the pool's hook once, before the
/// pool opens; `syncProtocol` then recognises the contracts the hook is wired to. The owner is the gate's admin
/// and has no other power. The genesis mint is not checked.
/// @custom:disclaimer Experimental software, not audited by an independent security firm. You may lose everything
/// you commit.
contract PoolToken is ERC20, ERC20Burnable, Ownable2Step, VenueGate {
    /// @notice May set the pool hook once.
    address public immutable deployer;

    error AlreadySet();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address distributor,
        address poolManager_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) VenueGate(poolManager_) {
        deployer = msg.sender;
        _mint(distributor, supply);
    }

    /// @notice Deployer only, once: sets the POOL/ETH pool's hook, the only one that can credit the pool manager
    /// budget.
    function setHook(address hook_) external {
        if (msg.sender != deployer || poolHook != address(0) || hook_ == address(0)) revert AlreadySet();
        _setPoolHook(hook_);
    }

    /// @notice Callable by anyone: recognises as protocol contracts the hook's gate (PoolLaunch), the gate's
    /// launcher (ScoreLiquidity), and the hook's Burner and Builder. Each is set once on the hook or the gate, so
    /// this only adds what the hook is already wired to.
    function syncProtocol() external {
        address h = poolHook;
        if (h == address(0)) return;
        address g = IHookWiring(h).gate();
        if (g != address(0)) {
            _markProtocol(g);
            _markProtocol(ILauncherOf(g).launcher());
        }
        _markProtocol(IHookWiring(h).burner());
        _markProtocol(IHookWiring(h).builder());
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _checkTransfer(from, to, value);
        super._update(from, to, value);
    }

    function _checkGateAdmin() internal view override {
        _checkOwner();
    }
}
