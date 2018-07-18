pragma solidity ^0.4.23;

import "./Set.sol";


contract Multiownable {

    using Set for Set.Data;

    uint256 public constant MAX_PENDING_OPERATIONS_PER_OWNER = 50;

    // VARIABLES

    uint256 public nextOwnerId = 1; // Unique for every reowning
    uint256 public howManyOwnersDecide;
    Set.Data internal owners;
    Set.Data internal operations;
    mapping(uint256 => Set.Data) internal operationsByOwnerId;
    mapping(address => uint256) public ownerIds;
    mapping(uint256 => address) public ownerById;
    mapping(bytes32 => uint256) public dataHashGeneration;
    mapping(bytes32 => uint256) public votesCountByOperation;
    mapping(bytes32 => bytes) public dataByOperation;
    
    address internal insideCallSender;
    uint256 internal insideCallCount;
    
    // EVENTS

    event OwnersAdded(address[] newOwners, uint newHowManyOwnersDecide);
    event OwnerRemoved(address oldOwner, uint newHowManyOwnersDecide);
    event OperationCreated(bytes32 operation, uint howMany, uint ownersCount, address proposer);
    event OperationUpvoted(bytes32 operation, uint votes, uint howMany, uint ownersCount, address upvoter);
    event OperationPerformed(bytes32 operation, uint howMany, uint ownersCount, address performer);
    event OperationDownvoted(bytes32 operation, uint votes, uint ownersCount,  address downvoter);
    event OperationCancelled(bytes32 operation, address lastCanceller);

    // ACCESSORS

    function isOwner(address wallet) public view returns(bool) {
        return owners.contains(bytes32(wallet));
    }

    function ownersLength() public view returns(uint) {
        return owners.length();
    }

    function ownerAt(uint i) public view returns(address) {
        return address(owners.at(i));
    }

    function allOwners() public view returns(bytes32[]) {
        return owners.items;
    }

    function operationsLength() public view returns(uint) {
        return operations.length();
    }

    function operationAt(uint i) public view returns(bytes32) {
        return operations.at(i);
    }

    function allOperations() public view returns(bytes32[]) {
        return operations.items;
    }

    function ownerOperationsLength(address theOwner) public view returns(uint256) {
        uint256 ownerId = ownerIds[theOwner];
        return operationsByOwnerId[ownerId].length();
    }

    function ownerOperationsAt(address theOwner, uint i) public view returns(bytes32) {
        uint256 ownerId = ownerIds[theOwner];
        return operationsByOwnerId[ownerId].at(i);
    }

    function allOwnerOperations(address theOwner) public view returns(bytes32[]) {
        uint256 ownerId = ownerIds[theOwner];
        return operationsByOwnerId[ownerId].items;
    }

    // MODIFIERS

    /**
    * @dev Allows to perform method by any of the owners
    */
    modifier onlyAnyOwner {
        require(isOwner(msg.sender));
        
        bool update = (insideCallSender == address(0));
        if (update) {
            insideCallSender = msg.sender;
            insideCallCount = 1;
        }
        _;
        if (update) {
            insideCallSender = address(0);
            insideCallCount = 0;
        }
    }

    /**
    * @dev Allows to perform method only after many owners call it with the same arguments
    */
    modifier onlyManyOwners {
        if (_voteAndCheck(howManyOwnersDecide)) {
            bool update = (insideCallSender == address(0));
            if (update) {
                insideCallSender = msg.sender;
                insideCallCount = howManyOwnersDecide;
            }
            _;
            if (update) {
                insideCallSender = address(0);
                insideCallCount = 0;
            }
        }
    }

    /**
    * @dev Allows to perform method only after all owners call it with the same arguments
    */
    modifier onlyAllOwners {
        if (_voteAndCheck(owners.length())) {
            bool update = (insideCallSender == address(0));
            if (update) {
                insideCallSender = msg.sender;
                insideCallCount = owners.length();
            }
            _;
            if (update) {
                insideCallSender = address(0);
                insideCallCount = 0;
            }
        }
    }

    /**
    * @dev Allows to perform method only after some owners call it with the same arguments
    */
    modifier onlySomeOwners(uint howMany) {
        require(howMany > 0, "onlySomeOwners: howMany argument is zero");
        require(howMany <= owners.length(), "onlySomeOwners: howMany argument exceeds the number of owners");

        if (_voteAndCheck(howMany)) {
            bool update = (insideCallSender == address(0));
            if (update) {
                insideCallSender = msg.sender;
                insideCallCount = howMany;
            }
            _;
            if (update) {
                insideCallSender = address(0);
                insideCallCount = 0;
            }
        }
    }

    // CONSTRUCTOR

    constructor() public {
        owners.add(bytes32(msg.sender));
        howManyOwnersDecide = 1;
    }

    // PRIVATE METHODS

    function _deleteOperation(bytes32 operation, bool done) private {
        operations.remove(operation);
        votesCountByOperation[operation] = done ? uint256(-1) : 0;
        delete dataByOperation[operation];
    }

    // INTERNAL METHODS

    /**
     * @dev onlyManyOwners modifier helper
     */
    function _voteAndCheck(uint howMany) internal returns(bool) {
        if (insideCallSender == msg.sender) {
            require(howMany <= insideCallCount, "_voteAndCheck: nested owners modifier check require more owners");
            return true;
        }

        require(owners.contains(bytes32(msg.sender)));
        uint256 ownerId = ownerIds[msg.sender];
        bytes32 calldataHash = keccak256(msg.data);
        bytes32 operation = bytes32(uint256(calldataHash) + dataHashGeneration[calldataHash]);

        if (operationsByOwnerId[ownerId].length() == MAX_PENDING_OPERATIONS_PER_OWNER) {
            cleanFinishedOperations(ownerId);
        }

        uint operationVotesCount = votesCountByOperation[operation] + 1;
        votesCountByOperation[operation] = operationVotesCount;
        require(operationsByOwnerId[ownerId].add(operation), "_voteAndCheck: owner already voted for the operation");
        require(operationsByOwnerId[ownerId].length() <= MAX_PENDING_OPERATIONS_PER_OWNER, "_voteAndCheck: owner exceeded number of pending operations");
        
        if (operationVotesCount == 1) {
            operations.add(operation);
            dataByOperation[operation] = msg.data;
            emit OperationCreated(operation, howMany, owners.length(), msg.sender);
        }
        emit OperationUpvoted(operation, operationVotesCount, howMany, owners.length(), msg.sender);

        return _checkVotes(howMany, operation, calldataHash);
    }

    function _checkVotes(uint howMany, bytes32 operation, bytes32 calldataHash) internal returns(bool) {
        // If enough owners confirmed the same operation
        if (votesCountByOperation[operation] >= howMany) {
            _deleteOperation(operation, true);
            dataHashGeneration[calldataHash]++;
            emit OperationPerformed(operation, howMany, owners.length(), msg.sender);
            return true;
        }

        return false;
    }

    function _cancelOperation(bytes32 operation, uint256 ownerId) internal {
        require(operationsByOwnerId[ownerId].remove(operation), "_cancelOperation: operation not found for this user");

        uint operationVotesCount = votesCountByOperation[operation] - 1;
        if (operationVotesCount != uint256(-2)) {
            votesCountByOperation[operation] = operationVotesCount;
            emit OperationDownvoted(operation, operationVotesCount, owners.length(), msg.sender);
            if (operationVotesCount == 0) {
                _deleteOperation(operation, false);
                emit OperationCancelled(operation, msg.sender);
            }
        }
    }

    function _addOwner(address newOwner) internal {
        require(newOwner != address(0), "_addOwner: owners array contains zero");
        require(owners.add(bytes32(newOwner)), "_addOwner: owners array contains duplicates");
        ownerIds[newOwner] = nextOwnerId;
        ownerById[nextOwnerId] = newOwner;
        nextOwnerId += 1;
    }

    function _removeOwner(address theOwner) internal {
        require(owners.remove(bytes32(theOwner)), "_removeOwner: theOwner do not exist");
        uint256 ownerId = ownerIds[theOwner];

        for (uint i = operationsByOwnerId[ownerId].length(); i > 0; i--) {
            bytes32 operation = operationsByOwnerId[ownerId].at(i - 1);
            _cancelOperation(operation, ownerId);
        }

        delete ownerById[ownerId];
        delete ownerIds[theOwner];
        emit OwnerRemoved(theOwner, howManyOwnersDecide);
    }

    function _setHowManyOwnersDecide(uint howMany) internal {
        require(howMany > 0, "_setHowManyOwnersDecide: howMany equal to 0");
        require(howMany <= owners.length(), "_setHowManyOwnersDecide: howMany exceeds the number of owners");
        howManyOwnersDecide = howMany;
    }

    // PUBLIC METHODS

    /**
    * @dev Allows owners to change their mind by cancelling votedByOperationAndIndex operations
    * @param operation defines which operation to cancel
    */
    function cancelOperation(bytes32 operation) public onlyAnyOwner {
        return _cancelOperation(operation, ownerIds[msg.sender]);
    }

    /**
    * @dev Allows owners to add new owners
    * @param newOwners defines array of addresses of new owners
    */
    function addOwners(address[] newOwners) public {
        addOwnersWithHowMany(newOwners, howManyOwnersDecide + newOwners.length);
    }

    /**
    * @dev Allows owners to remove themselves
    */
    function resignOwnership() public onlyAnyOwner {
        require(owners.length() > 1);
        _removeOwner(msg.sender);
        if (howManyOwnersDecide > 1) {
            howManyOwnersDecide -= 1;
        }
    }

    /**
    * @dev Allows owners to remove other owners
    */
    function removeOwners(address[] theOwners) public {
        removeOwnersWithHowMany(theOwners, howManyOwnersDecide > theOwners.length ? howManyOwnersDecide - theOwners.length : 1);
    }

    /**
    * @dev Allows owners to add new owners
    * @param newOwners defines array of addresses of new owners
    * @param newHowManyOwnersDecide defines how many owners can decide
    */
    function addOwnersWithHowMany(address[] newOwners, uint256 newHowManyOwnersDecide) public onlyManyOwners {
        for (uint i = 0; i < newOwners.length; i++) {
            _addOwner(newOwners[i]);
        }
        _setHowManyOwnersDecide(newHowManyOwnersDecide);
        emit OwnersAdded(newOwners, howManyOwnersDecide);
    }

    /**
    * @dev Allows owners to transfer ownership to new ones
    * @param newOwners defines array of addresses of new owners
    * @param howMany defines how many owners can decide
    */
    function transferOwnershipWithHowMany(address[] newOwners, uint256 howMany) public onlyManyOwners {
        require(newOwners.length > 0, "transferOwnershipWithHowMany: newOwners length should be at least 1");
        for (uint i = owners.length(); i > 0; i--) {
            address oldOwner = address(owners.at(i - 1));
            _removeOwner(oldOwner);
        }
        addOwnersWithHowMany(newOwners, howMany);
    }

    /**
    * @dev Allows owners to remove other owners
    * @param theOwners defines array of addresses of old owners
    * @param howMany defines how many owners can decide
    */
    function removeOwnersWithHowMany(address[] theOwners, uint256 howMany) public onlyManyOwners {
        require(owners.length() > theOwners.length);
        for (uint  i = 0; i < theOwners.length; i++) {
            _removeOwner(theOwners[i]);
        }
        _setHowManyOwnersDecide(howMany);
    }

    function cleanFinishedOperations(uint256 ownerId) public {
        bool isNotAnOwnerAnymore = (ownerById[ownerId] == address(0));
        for (uint i = operationsByOwnerId[ownerId].length(); i > 0; i--) {
            bytes32 operation = operationsByOwnerId[ownerId].at(i - 1);
            if (isNotAnOwnerAnymore || votesCountByOperation[operation] == uint256(-1)) {
                _cancelOperation(operation, ownerId);
            }
        }
    }

}
