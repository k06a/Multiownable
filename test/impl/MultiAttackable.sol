pragma solidity ^0.4.11;

import "../../contracts/Multiownable.sol";


contract MultiAttackable is Multiownable {

    function() public payable {
    }

    function transferTo(address to, uint256 amount) public onlyManyOwners {
        // solium-disable-next-line security/no-call-value
        require(to.call.value(amount)());
        //to.transfer(amount);
    }

}
