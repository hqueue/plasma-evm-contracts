pragma solidity ^0.4.24;

import "./lib/SafeMath.sol";
import "./lib/Math.sol";
import "./lib/Data.sol";


// TODO: use SafeMath
contract RootChain {
  using SafeMath for uint;
  using Math for *;
  using Data for *;

  enum State {
    AcceptingNRB,
    AcceptingORB,
    // TODO: remove AcceptingURB
    AcceptingURB
  }

  /*
   * Storage
   */
  address public operator;
  State public state;

  // Increase for each URB
  uint public currentFork;

  // First epoch of a fork
  mapping (uint => uint) public firstEpoch;

  // Increase for each epoch
  uint public currentEpoch;

  // Highest block number of the fork
  mapping (uint => uint) public highestBlockNumber;

  // fork => block number
  mapping (uint => uint) public lastFinalizedBlock;

  // fork => block number => PlasmaBlock
  mapping (uint => mapping (uint => Data.PlasmaBlock)) public blocks;

  // fork => epoch number => Epoch
  mapping (uint => mapping (uint => Data.Epoch)) public epochs;

  // 1 epoch = N NRBs or k URBs or k ORBs.
  // N consecutive NRBs must be submitted in an epoch. In case of request block,
  // massive requests can be included in k ORBs, and k is determined when
  // N NRBs are submitted or when preparing URBs submission.
  uint public NRBEpochLength;

  // Enter & Exit requests for ORB / URB
  Data.Request[] public EROs;
  Data.Request[] public ERUs;

  // Requests info for the ORBs in a single epoch of a fork
  mapping (uint => mapping (uint => Data.RequestBlock[])) public ORBs;

  // Requests info for the URBs in a fork
  mapping (uint => Data.RequestBlock[]) public URBs;

  // Last finalized reqeust block
  uint public lastFinalizedORB;
  uint public lastFinalizedURB;

  // Last finalize request
  uint public lastFinalizedERO;
  uint public lastFinalizedERU;

  // TODO: develop cost function
  // Simple cost parameters
  uint public constant COST_ERO = 0.1 ether;         // cost for invalid exit
  uint public constant COST_ERU = 0.2 ether;         // cost for fork & rebase
  uint public constant COST_URB_PREPARE = 0.1 ether; // cost for URB prepare
  uint public constant COST_URB = 0.9 ether;         // cost for fork & rebase
  uint public constant COST_ORB = 0.1 ether;         // cost for invalid computation
  uint public constant COST_NRB = 0.1 ether;         // cost for invalid computation

  // Prepare time
  uint public constant PREPARE_TIMEOUT = 1 hours;

  // Challenge periods for computation and withholding
  uint public constant CP_COMPUTATION = 1 days;
  uint public constant CP_WITHHOLDING = 7 days;

  // How many requests can be included in a single request block
  uint public constant MAX_REQUESTS = 1000;

  // Gas limit for request trasaction
  uint public constant REQUEST_GAS = 100000;


  /*
   * Event
   */
  event SessionTimeout(bool userActivated);
  event StateChanged(State state);

  event Forked(uint newFork, uint forkedBlockNumber);

  event NRBSubmitted(uint fork, uint blockNumber);
  event ORBSubmitted(uint fork, uint blockNumber);
  event URBSubmitted(uint fork, uint blockNumber);

  event RequestCreated(
    uint requestId,
    address requestor,
    address to,
    bytes32 trieKey,
    bytes32 trieValue,
    bool isExit
  );
  event ERUCreated(
    uint requestId,
    address requestor,
    address to,
    bytes32 trieKey,
    bytes32 trieValue
  );

  event BlockFinalized(uint _forkNumber, uint _blockNumber);
  event EpochFinalized(uint _forkNumber, uint _epochNumber, uint _firstBlockNumber, uint _lastBlockNumber);

  // emit when exit is finalized. _userActivated is true for ERU
  event ExitFinalized(uint _requestId, uint _userActivated);

  /*
   * Modifier
   */
  modifier onlyOperator() {
    require(msg.sender == operator);
    _;
  }

  modifier onlyState(State _state) {
    require(state == _state);
    _;
  }

  modifier onlyNotState(State _state) {
    require(state != _state);
    _;
  }

  modifier onlyValidCost(uint _expected) {
    require(msg.value == _expected);
    _;
  }

  modifier finalizeBlocks() {
    _finalizeBlock();
    _;
  }

  /**
   * Constructor
   */
  constructor(
    uint _NRBEpochLength,

    // genesis block state
    bytes32 _statesRoot,
    bytes32 _transactionsRoot,
    bytes32 _intermediateStatesRoot
  )
    public
  {
    operator = msg.sender;
    NRBEpochLength = _NRBEpochLength;

    Data.PlasmaBlock storage genesis = blocks[currentFork][0];
    genesis.statesRoot = _statesRoot;
    genesis.transactionsRoot = _transactionsRoot;
    genesis.intermediateStatesRoot = _intermediateStatesRoot;

    _doFinalize(genesis, 0);
    _prepareToSubmitNRB();
  }


  /*
   * External Functions
   */

  /**
   * @notice Declare to submit URB.
   */
  function prepareToSubmitURB()
    external
    onlyOperator
    onlyValidSession(currentURBSession, true)
    returns (bool)
  {
    state = State.AcceptingURB;
    _prepareToSubmitURB();
    return true;
  }

  // TODO: Delegate the validity check to TrueBit Verification Game contracts
  function submitNRB(
    bytes32 _statesRoot,
    bytes32 _transactionsRoot,
    bytes32 _intermediateStatesRoot
  )
    external
    onlyOperator
    onlyState(State.AcceptingNRB)
    onlyValidCost(COST_NRB)
    returns (bool)
  {
    uint blockNumber = _storeBlock(
      _statesRoot,
      _transactionsRoot,
      _intermediateStatesRoot,
      false,
      false,
      false
    );

    Epoch storage epoch = epochs[currentFork][currentEpoch];
    uint numBlocks = epoch.getNumBlocks();
    uint submittedBlocks = highestBlockNumber[currentFork] - epoch.startBlockNumber + 1;

    if (submittedBlocks == numBlocks) {
      _prepareToSubmitORB();
    }

    emit NRBSubmitted(currentFork, blockNumber);
    return true;
  }


  function submitORB(
    bytes32 _statesRoot,
    bytes32 _transactionsRoot,
    bytes32 _intermediateStatesRoot
  )
    external
    onlyOperator
    onlyState(State.AcceptingORB)
    onlyValidCost(COST_ORB)
    returns (bool)
  {
    uint blockNumber = _storeBlock(
      _statesRoot,
      _transactionsRoot,
      _intermediateStatesRoot,
      true,
      false,
      false
    );

    Epoch storage epoch = epochs[currentFork][currentEpoch];
    uint numBlocks = epoch.getNumBlocks();
    uint submittedBlocks = highestBlockNumber[currentFork] - epoch.startBlockNumber + 1;

    // TODO: verify merkle root

    if (submittedBlocks == numBlocks) {
      _prepareToSubmitNRB();
    }

    emit ORBSubmitted(currentFork, blockNumber);
    return true;
  }

  function submitURB(
    bytes32 _statesRoot,
    bytes32 _transactionsRoot,
    bytes32 _intermediateStatesRoot
  )
    external
    payable
    onlyState(State.AcceptingURB)
    onlyValidCost(COST_URB)
    returns (bool)
  {
    bool firstURB = !blocks[currentFork][highestBlock[current]].request;

    uint blockNumber = _storeBlock(
      _statesRoot,
      _transactionsRoot,
      _intermediateStatesRoot,
      true,
      true,
      firstURB
    );

    if (blockNumber != 0) {
      Epoch storage epoch = epochs[currentFork][currentEpoch];
      uint numBlocks = epoch.getNumBlocks();
      uint submittedURBs = highestBlockNumber[currentFork] - epoch.startBlockNumber + 1;

      // TODO: verify merkle root

      if (submittedURBs == numBlocks) {
        _prepareToSubmitNRB();
      }

      emit ORBSubmitted(currentFork, blockNumber);
      return true;
    }

    return false;
  }

  /**
   * @notice Computation verifier contract reverts the block in case of wrong
   *         computation.
   */
  function revertBlock(uint _forkNumber, uint _blockNumber) external {
    // TODO: make a new fork?
  }

  /**
   * @notice It challenges on NRBs containing Null Address transaction.
   */
  function challengeNATX(uint _blockNumber, bytes _key, bytes _txData, uint _branchMask, bytes32[] _siblings) external {
    Data.PlasmaBlock storage pb = blocks[currentFork][_blockNumber];

    // check the plasma block is NRB
    require(!pb.isRequest);

    // check the challenge period
    require(pb.timestamp + CP_COMPUTATION > block.timestamp);

    bytes32 root = pb.transactionsRoot;
    bytes32 txHash;

    /* TODO: implement Data.Transaction, MPT

    Data.Transaction memory tx = _txData().toTransaction();
    require(tx.from == NullAddress);
    require(root.verifyProof(bytes _key, _txData, _branchMask, _siblings));

    */


    // TODO: fork? penalize?
  }

  /*
   * Public Functions
   */
  function startExit(
    address _to,
    bytes32 _trieKey,
    bytes32 _trieValue
  )
    public
    onlyValidCost(COST_ERO)
    returns (bool)
  {
    uint requestId = _storeRequest(EROs, _to, _trieKey, _trieValue, true);

    emit RequestCreated(requestId, msg.sender, _to, _trieKey, _trieValue, true);
    return true;
  }

  function startEnter(
    address _to,
    bytes32 _trieKey,
    bytes32 _trieValue
  )
    public
    returns (bool)
  {
    uint requestId = _storeRequest(EROs, _to, _trieKey, _trieValue, false);

    emit RequestCreated(requestId, msg.sender, _to, _trieKey, _trieValue, false);
    return true;
  }

  function makeERU(
    address _to,
    bytes32 _trieKey,
    bytes32 _trieValue
  )
    public
    onlyValidCost(COST_ERU)
    returns (bool)
  {
    uint requestId = _storeRequest(ERUs, _to, _trieKey, _trieValue, true);

    emit ERUCreated(requestId, msg.sender, _to, _trieKey, _trieValue);
    return true;
  }

  /**
   * @notice finalize last Enter or Exit request. this returns the bond in both of
   *         request types. For exit request, this calls applyRequestInRootChain
   *         function of the requestable contract in root chain.
   */
  function finalizeRequest() public returns (bool) {
    if (!_finalizeERU()) {
      return _finalizeERO();
    }

    return true;
  }

  /**
   * @notice return true if the chain is forked by URB
   */
  function forked(uint _forkNumber) public returns (bool) {
    return _forkNumber != currentFork;
  }

  /**
   * @notice return true if the request is finalized
   */
  function getRequestFinalized(uint _requestId, uint _userActivated) public view returns (bool) {
    if (_userActivated) {
      ERUs[_requestId].finalized;
    }

    return EROs[_requestId].finalized;
  }


  /*
   * Internal Functions
   */
  function _storeBlock(
    bytes32 _statesRoot,
    bytes32 _transactionsRoot,
    bytes32 _intermediateStatesRoot,
    bool _isRequest,
    bool _userActivated
  )
    internal
    returns (uint blockNumber)
  {
    if (_isRequest && _userActivated && _firstURB) {
      uint nextFork = currentFork.add(1);

      // NOTE: can targetEpoch be 0?
      uint forkEpochNumber = blocks[currentEpoch][lastFinalizedBlock[currentFork] + 1].epochNumber;

      Data.Epoch storage newEpoch = epochs[nextFork][forkEpochNumber];

      // URB submission is out of time
      if (newEpoch.isRequest && newEpoch.timestamp + PREPARE_TIMEOUT < block.timestamp) {
        firstEpoch[nextFork] = 0;
        delete epochs[nextFork];
        return;
      }

      // update storage
      currentFork = nextFork;
      blockNumber = epochs[currentFork].startBlockNumber;
      epochs[currentFork - 1][forkEpochNumber].forkedBlockNumber = blockNumber;

      emit Forked(nextFork, blockNumber);
    } else {
      blockNumber = highestBlockNumber[currentFork].add(1);
    }

    Data.PlasmaBlock storage b = blocks[currentFork][blockNumber];

    b.statesRoot = _statesRoot;
    b.transactionsRoot = _transactionsRoot;
    b.intermediateStatesRoot = _intermediateStatesRoot;
    b.isRequest = _isRequest;
    b.userActivated = _userActivated;

    highestBlockNumber[currentFork] = blockNumber;
    return;
  }

  function _storeRequest(
    Data.Request[] storage _requests,
    address _to,
    bytes32 _trieKey,
    bytes32 _trieValue,
    bool _isExit
  )
    internal
    returns (uint requestId)
  {
    requestId = _requests.length++;
    Data.Request storage r = _requests[requestId];

    r.requestor = msg.sender;
    r.to = _to;
    r.trieKey = _trieKey;
    r.trieValue = _trieValue;
    r.timestamp = uint64(block.timestamp);
    r.isExit = _isExit;
  }

  /**
   * @notice prepare to submit ORB. It prevents further new requests from
   * being included in the request blocks in the just next ORB epoch.
   */
  function _prepareToSubmitORB() internal {
    uint startBlockNumber = highestBlockNumber[currentEpoch].add(1);

    currentEpoch += 1;
    Data.Epoch storage epoch = epochs[currentFork][currentEpoch];

    if (currentEpoch == 1) {
      // first ORB epoch
      epoch.requestStart = 0;
    } else {
      // last request id of previous ORB epoch + 1
      epoch.requestStart = epochs[currentFork][currentEpoch - 2].requestEnd + 1;
    }

    epoch.isRequest = true;
    epoch.requestEnd = uint64(EROs.length.sub(1));
    epoch.startBlockNumber = startBlockNumber;
    epoch.endBlockNumber = uint64(startBlockNumber + uint(epoch.requestEnd - epoch.requestStart + 1).divCeil(MAX_REQUESTS) - 1);

    // change state to accept ORBs
    state = State.AcceptingORB;
    emit StateChanged(state);

    // no ORB to submit
    if (epoch.getNumBlocks() == 0) {
      _prepareToSubmitNRB();
    }
  }

  function _prepareToSubmitNRB() internal {
    uint startBlockNumber = highestBlockNumber[currentEpoch].add(1);

    currentEpoch += 1;
    Data.Epoch storage epoch = epochs[currentFork][currentEpoch];

    epoch.startBlockNumber = startBlockNumber;
    epoch.endBlockNumber = uint64(startBlockNumber + NRBEpochLength - 1);

    // change state to accept NRBs
    state = State.AcceptingNRB;
    emit StateChanged(state);
  }

  function _prepareToSubmitURB() internal {
    // NOTE: what if no finalized block at this fork?

    uint lastBlockNumber = lastFinalizedBlock[currentFork];
    Data.PlasmaBlock storage lastBlock = blocks[lastBlockNumber];

    uint nextFork = currentFork + 1;
    uint forkEpochNumber = lastBlock.epochNumber;

    // note epoch number for the new fork
    firstEpoch[nextFork] = forkEpochNumber;

    Data.Epoch storage epoch = epochs[nextFork][forkEpochNumber];

    if (nextFork == 1) {
      // first URB fork
      epoch.requestStart = 0;
    } else {
      // last ERU id of previous URB fork + 1
      epoch.requestStart = epochs[currentFork][firstEpoch[currentFork]].requestEnd + 1;
    }

    epoch.isRequest = true;
    epoch.userActivated = true;
    epoch.requestEnd = uint64(ERUs.length.sub(1));
    epoch.startBlockNumber = lastBlockNumber + 1;
    epoch.endBlockNumber = uint64(startBlockNumber + uint(epoch.requestEnd - epoch.requestStart + 1).divCeil(MAX_REQUESTS) - 1);
  }

  function _finalizeBlock() internal onlyNotState(State.AcceptingURB) {
    uint blockNumber = lastFinalizedBlock[currentFork] + 1;

    // short circuit if all blocks are finalized
    if (blockNumber > highestBlockNumber[currentFork]) {
      return;
    }

    Data.PlasmaBlock storage pb = blocks[currentFork][blockNumber];

    // short circuit if the block is under challenge
    if (pb.challenging) {
      return;
    }

    // 1. finalize request block
    if (pb.isRequest) {
      // return if challenge period doesn't end
      if (pb.timestamp + CP_COMPUTATION <= block.timestamp) {
        return;
      }

      // finalize block
      _doFinalize(pb, blockNumber);
      return;
    }

    // 2. finalize non request block

    uint nextEpochNumber = pb.epochNumber + 1;

    // if the first block of the next request epoch is finalized, finalize all
    // blocks of the current non request epoch.
    if (_checkFinalizable(nextEpochNumber)) {
      _doFinalizeEpoch(pb.epochNumber);
      return;
    }

    // short circuit if challenge period doesn't end
    if (pb.timestamp + CP_WITHHOLDING <= block.timestamp) {
      return;
    }

    // finalize block
    _doFinalize(pb, blockNumber);
    return;
  }

  /**
   * @notice return true if the first block of a request epoch (ORB epoch / URB epoch)
   *         can be finalized.
   */
  function _checkFinalizable(uint _epochNumber) internal returns (bool) {
    // cannot finalize future epoch
    if (_epochNumber > currentEpoch) {
      return false;
    }

    Data.Epoch storage epoch = epochs[currentFork][_epochNumber];

    // cannot finalize if it is not request epoch
    if (!epoch.isRequest) {
      return false;
    }

    // cannot finalize if the first block was not submitted
    if (_epochNumber == currentEpoch && epoch.startBlockNumber > highestBlockNumber[currentFork]) {
      return false;
    }

    Data.PlasmaBlock storage pb = blocks[currentFork][epoch.startBlockNumber];

    // the block was already finalized
    if (pb.finalized) {
      return true;
    }

    // short circuit if the request block is under challenge
    if (pb.challenging) {
      return false;
    }

    // return true if challenge period end
    if (pb.timestamp + CP_COMPUTATION > block.timestamp) {
      return true;
    }

    return false;
  }

  /**
   * @notice finalize a block
   */
  function _doFinalize(Data.PlasmaBlock storage _pb, uint _blockNumber) internal {
    pb.finalized = true;
    lastFinalizedBlock[currentFork] = _blockNumber;

    emit BlockFinalized(currentFork, _blockNumber);
  }

  /**
   * @notice finalize all blocks in the non request epoch
   */
  function _doFinalizeEpoch(uint _epochNumber) internal {
    Data.Epoch storage epoch = epochs[currentFork][_epochNumber];

    uint i;
    bool stopped;
    for(i = epoch.startBlockNumber; i <= epoch.endBlockNumber; i++) {
      Data.PlasmaBlock storage pb = blocks[currentFork][i];

      // shrot circuit if block is under challenge or challenged
      if (pb.challenging || pb.challenged) {
        stopped = true;
        break;
      }

      pb.finalized = true;
    }

    uint lastBlockNumber = stopped ? i - 1 : i;

    if (lastBlockNumber >= epoch.startBlockNumber) {
      lastFinalizedBlock[currentFork] = lastBlockNumber;
      emit EpochFinalized(currentFork, _epochNumber, epoch.startBlockNumber, lastBlockNumber);
    }

    return;
  }

  /**
   * @notice finalize ERUs in the first epoch of current fork.
   *         return true if an ERU is finalized.
   */
  function _finalizeERU() internal returns (bool) {
    // short circuit if not forked yet
    if (currentFork != 0) {
      return false;
    }

    Data.Epoch storage e1 = epoch[currentFork - 1][firstEpoch[currentFork] - 1];
    Data.Epoch storage epoch = epoch[currentFork][firstEpoch[currentFork]];

    if (e1.isRequest) {
      return _finalizeERUWithEpoch(epoch, e1);
    }

    Data.Epoch storage e2 = epoch[currentFork - 1][firstEpoch[currentFork] - 2];
    return _finalizeERUWithEpoch(epoch, e2);
  }

  function _finalizeERUWithEpoch(
    Data.Epoch storage _epoch,
    Data.Epoch storage _lastRequestEpoch
  )
    internal
    returns (bool)
  {
    // short circuit if EROs are not finalized yet
    if (lastFinalizedERO < ORBEpoch.requestStart) {
      return false;
    }

    // short circuit if all ERUs is finalized
    if (lastFinalizedERU == ERUs.length - 1) {
      return false;
    }

    uint requestId = lastFinalizedERU + 1;
    uint blockNumber = epoch.getBlockNumber(requestId)

    Data.PlasmaBlock storage pb = blocks[blockNumber];
    Data.Request storage ERU = ERUs[requestId];

    return true;
  }

  /**
   * @notice finalize ERUs in the first epoch of current fork.
   *         return true if an ERU is finalized.
   */
  function _finalizeERO() internal returns (bool) {

  }
}
