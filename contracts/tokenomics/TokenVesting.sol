// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "../Ownable.sol";
import "../SafeMath.sol";
import "../ERC20.sol";
import "../SafeERC20.sol";

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 */
contract TokenVesting is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for ERC20;

  event Released(uint256 amount);
  event Revoked();

  ERC20 erc20Token;

  // beneficiary of tokens after they are released
  string public name;

  address public beneficiary;

  uint256 public cliff;
  uint256 public start;
  uint256 public duration;
  uint256 public tge;

  bool public revocable;

  uint256 public released;
  bool public revoked;

  /**
   * @dev Creates a vesting contract that vests its balance of any ERC20 token to the
   * _beneficiary, gradually in a linear fashion until _start + _duration. By then all
   * of the balance will have vested.
   * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
   * @param _cliff duration in seconds of the cliff in which tokens will begin to vest
   * @param _duration duration in seconds of the period in which the tokens will vest
   * @param _revocable whether the vesting is revocable or not
   */
  constructor(string memory _name, address _erc20Token, address _beneficiary, 
            uint256 _start, uint256 _cliff, uint256 _duration, uint256 _tge, bool _revocable) {
    name = _name;

    require(_erc20Token != address(0), "TokenVesting: erc20 token is zero address");
    require(_beneficiary != address(0), "TokenVesting: beneficiary is zero address");

    erc20Token = ERC20(_erc20Token);

    beneficiary = _beneficiary;
    revocable = _revocable;
    duration = _duration;

    if (_start == 0)
      start = block.timestamp;
    else
      start = _start;

    cliff = start.add(_cliff);
    tge = _tge;
  }

  /**
   * @notice Transfers vested tokens to beneficiary.
   */
  function release() external {
    uint256 unreleased = releasableAmount();

    require(unreleased > 0, "TokenVesting: no releasable token");

    released = released.add(unreleased);

    erc20Token.safeTransfer(beneficiary, unreleased);

    emit Released(unreleased);
  }

  /**
   * @notice Allows the owner to revoke the vesting. Tokens already vested
   * remain in the contract, the rest are returned to the owner.
   */
  function revoke() external onlyOwner {
    require(revocable, "TokenVesting: this contract is not revocable");
    require(!revoked, "TokenVesting: already revoked");

    uint256 balance = erc20Token.balanceOf(address(this));

    uint256 unreleased = releasableAmount();
    uint256 refund = balance.sub(unreleased);

    revoked = true;

    erc20Token.safeTransfer(owner(), refund);

    emit Revoked();
  }

  /**
   * @dev Calculates the amount that has already vested but hasn't been released yet.
   */
  function releasableAmount() public view returns (uint256) {
    return vestedAmount().sub(released);
  }

  /**
   * @dev Calculates the amount that has already vested.
   */
  function vestedAmount() public view returns (uint256) {
    uint256 currentBalance = erc20Token.balanceOf(address(this));
    uint256 totalBalance = currentBalance.add(released);

    if (block.timestamp < cliff) {
      return 0;
    } else if (block.timestamp >= cliff.add(duration) || revoked) {
      return totalBalance;
    } else {
      uint256 tgeAmount = totalBalance.mul(tge).div(100);
      uint256 durationAmount = totalBalance.sub(tgeAmount);
      if (duration != 0)
        durationAmount = durationAmount.mul(block.timestamp.sub(cliff)).div(duration);
      return tgeAmount.add(durationAmount);
    }
  }
}