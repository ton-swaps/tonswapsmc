pragma solidity >=0.5.0;

contract TonSwapOrderbook {

  /*
    Constants
  */

  // Exception codes:
  uint constant ERROR_INVALID_FUNCTION_ID = 101;
  uint constant ERROR_MSG_VALUE_TOO_LOW = 102;
  uint constant ERROR_USER_NOT_EXISTS_IN_DB = 103;
  uint constant ERROR_USER_INSUFFICIENT_BALANCE = 104;
  uint constant ERROR_INVALID_TIME_LOCK_SLOT = 105;
  uint constant ERROR_INVALID_MIN_VALUE = 106;
  uint constant ERROR_INVALID_EXCHANGE_RATE = 107;
  uint constant ERROR_INVALID_SECRET_HASH = 108;
  uint constant ERROR_INVALID_FOREIGN_ADDRESS = 109;
  uint constant ERROR_INVALID_ADDRESS = 110;
  uint constant ERROR_INVALID_VALUE = 111;
  uint constant ERROR_INVALID_DB = 112;
  uint constant ERROR_INVALID_ORDER_EXISTS = 113;
  uint constant ERROR_INVALID_ORDER_NOT_EXISTS = 114;
  uint constant ERROR_INVALID_ORDER_CONFIRMED = 115;
  uint constant ERROR_INVALID_ORDER_NOT_CONFIRMED = 116;
  uint constant ERROR_SUB_OVERFLOW = 117;
  uint constant ERROR_ADD_OVERFLOW = 118;
  uint constant ERROR_VALUE_ROUNDED = 119;
  uint constant ERROR_VALUE_RANGE = 120;
  uint constant ERROR_INVALID_SECRET = 121;
  uint constant ERROR_NOT_EXPIRED = 122;


  // Swap constants
  uint256 constant EXTRA_VALUE = 1000000000; // 1 CRYSTAL
  uint32 constant TIMELOCK_MIN = 3600; // 1 hour
  uint32 constant TIMELOCK_MAX = 604800; // 1 week

  // Swap Conversion directions
  uint32 constant SWAP_DIRECT_TON_ETH = 0;
  uint32 constant SWAP_DIRECT_TON_USDT = 1;
  uint32 constant SWAP_DIRECT_TON_BTC = 2;
  uint32 constant SWAP_DIRECT_MAX = 3;

  uint32 constant SWAP_REVERSED_ETH_TON = 0;
  uint32 constant SWAP_REVERSED_USDT_TON = 1;
  uint32 constant SWAP_REVERSED_BTC_TON = 2;
  uint32 constant SWAP_REVERSED_MAX = 3;

  // Rounding constants
  uint256 constant ETH_ROUND_EXP = 1000000000;
  uint256 constant USDT_ROUND_EXP = 100;
  uint256 constant BTC_ROUND_EXP = 100;

  /*
    Misc stuff
  */
  fallback() external {
    // Throw an exception on invalid function id.
      revert(ERROR_INVALID_FUNCTION_ID, "The inbound message has invalid function id");
  }

  onBounce(TvmSlice /*body*/) external {
    // Do nothing
  }


  /*
    PARTICIPANT DB PART
  */

  struct ParticipantBalance {
    // free value (in TON nanoCRYSTALS)
    uint256 value;
    // value in opened orders (in TON nanoCRYSTALS)
    uint256 inOrders;
    // value locked in active orders (in TON nanoCRYSTALS)
    uint256 locked;
  }

  mapping(address => ParticipantBalance) participantDB;


  /*
    Function for deposit
  */
  receive() external {
    
    address sender = msg.sender;
    uint256 value = msg.value;
    
    // Value for balance deposit
    // This subtraction cannot overflow
    require(msg.value > EXTRA_VALUE, ERROR_MSG_VALUE_TOO_LOW);
    value -= EXTRA_VALUE;
  
    // Get participant balance if exists
    bool exists = participantDB.exists(sender);
    if (exists) {
      ParticipantBalance balance = participantDB[sender];

      // Increase sender balance
      balance.value = add256(balance.value, value);
      
      // update DB record
      participantDB[sender] = balance;
      
      // flag = 0 is used for ordinary messages
      // bit 0 is not set, so the gas fees are deducted from EXTRA_VALUE amount
      // flag = flag + 2 means that any errors arising while processing this message during the action phase should be ignored.
      // msg.sender.transfer({value: uint128(EXTRA_VALUE), bounce: false, flag: 2});
      // msg.sender.transfer({value: uint128(EXTRA_VALUE), bounce: false, flag: 1});
    } else {
      // Create new DB record
      participantDB[sender] = ParticipantBalance({value:value, inOrders:uint256(0), locked:uint256(0)});
      
      // flag = 0 is used for ordinary messages
      // bit 0 is not set, so the gas fees are deducted from EXTRA_VALUE amount
      // flag = flag + 2 means that any errors arising while processing this message during the action phase should be ignored.
      // msg.sender.transfer({value: uint128(EXTRA_VALUE), bounce: false, flag: 0});
    }
  }

  /*
    Function for withdraw
    
    amount - value to withdraw in TON nanoCRYSTALS
  */
  function withdraw (uint256 amount) external {

    address sender = msg.sender;
  
    bool exists = participantDB.exists(sender);
    // Throws if sender is not exists in DB
    // The message must be sent with the bounce flag
    // All funds in message (msg.value) will be returned (bounced) except fees in this case
    require(exists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance balance = participantDB[sender];
    
    // Requested value must be less than or equal to the current balance
    require(amount <= balance.value, ERROR_USER_INSUFFICIENT_BALANCE);
    
    // Decrease participant balance
    // This subtraction cannot overflow
    balance.value -= amount;
    
    // Delete participants with no balance
    if (balance.value == uint256(0) && balance.inOrders == uint256(0) && balance.locked == uint256(0)) {
      delete participantDB[sender];
    } else {
      // or update DB
      participantDB[sender] = balance;
    }
    
    // Transfer funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (amount in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(amount), bounce: false, flag: 64});
  }

  /*
    Get current balance
  */
  function getBalance (address participant) view public returns (ParticipantBalance balance) {
    balance = participantDB[participant];
  }

  /*
    SWAP ORDERBOOK PART
  */

  uint256 SWAP_ETH_SMC_ADDRESS = 0;
  uint256 SWAP_ETH_TOKEN_SMC_ADDRESS = 0;

  /*
    Getters for Ethereum swap addresses
  */
  function getEthSmcAddress () view public returns(uint256 ethSmcAddress) {
      ethSmcAddress = SWAP_ETH_SMC_ADDRESS;
  }
  function getEthTokenSmcAddress () view public returns(uint256 ethTokenSmcAddress) {
      ethTokenSmcAddress = SWAP_ETH_TOKEN_SMC_ADDRESS;
  }

  struct SwapDirectOrder {
    // is order confirmed by confirmator
    bool confirmed;
    // Time when order is confirmed
    uint32 confirmTime;
    
    /* part for order initiator */
    
    // order max value in TON nanoCRYSTALS
    uint256 value;
    // order minimum value in TON nanoCRYSTALS
    uint256 minValue;
    // Exchange rate
    // Foreign tokens for 1 TON CRYSTAL (1000000000 nanoCRYSTALS)
    // Foreign tokens is indicated in the smallest denomination (wei for ETH, 0.000001 for USDT, satoshi for BTC, etc)
    uint256 exchangeRate;
    // Time lock slot is seconds
    uint32 timeLockSlot;
    // hash(secret)
    bytes32 secretHash;
    // initiator Foreign token Address
    // 256 bits is essential for Ethereum and Bitcoin
    uint256 initiatorTargetAddress;
    
    /* part for order confirmator */
    
    // Confirmator TON address
    address confirmatorTargetAddress;
    // Confirmator Foreign token source Address
    // 256 bits is essential for Ethereum and Bitcoin
    uint256 confirmatorSourceAddress;
  }

  struct SwapReversedOrder {
    // is order confirmed by confirmator
    bool confirmed;
    // Time when order is confirmed
    uint32 confirmTime;
    
    /* part for order initiator */
    
    // order max value in Foreign tokens (the smallest denomination)
    uint256 foreignValue;
    // order minimum value Foreign tokens (the smallest denomination)
    uint256 foreignMinValue;
    // Exchange rate
    // Foreign tokens for 1 TON CRYSTAL (1000000000 nanoCRYSTALS)
    // Foreign tokens is indicated in the smallest denomination (wei for ETH, 0.000001 for USDT, satoshi for BTC, etc)
    uint256 exchangeRate;
    // Time lock slot is seconds
    uint32 timeLockSlot;
    // Initiator Foreign token source Address
    // 256 bits is essential for Ethereum and Bitcoin
    uint256 initiatorSourceAddress;
    
    /* part for order confirmator */
    
    // Confirmed order value in TON nanoCRYSTALS
    uint256 value;
    // Confirmator TON address
    address confirmatorSourceAddress;
    // Confirmator Foreign token target Address
    // 256 bits is essential for Ethereum and Bitcoin
    uint256 confirmatorTargetAddress;
    // hash(secret)
    bytes32 secretHash;
  }

  struct SwapDirectDB {
    mapping(address => SwapDirectOrder) orders; 
  }

  struct SwapReversedDB {
    mapping(address => SwapReversedOrder) orders; 
  }

  SwapDirectDB[] swapDirectDB;
  SwapReversedDB[] swapReversedDB;

  /*
    Constructor
    
    ethSmcAddress - Ethereurm swap smart contract address
    ethTokenSmcAddress - Ethereurm Token swap smart contract address
  */
  constructor(uint256 ethSmcAddress, uint256 ethTokenSmcAddress) public {
    tvm.accept();
    
    SWAP_ETH_SMC_ADDRESS = ethSmcAddress;
    SWAP_ETH_TOKEN_SMC_ADDRESS = ethTokenSmcAddress;

    for (int i = 0; i < SWAP_DIRECT_MAX; i++) {
      swapDirectDB.push(SwapDirectDB());
    }
    for (int i = 0; i < SWAP_REVERSED_MAX; i++) {
      swapReversedDB.push(SwapReversedDB());
    }
  }

  /*
    DIRECT SWAPS
  */

  /*
    Create order with direct direction (Free TON -> Alt currency)
    
    dbId - swap direction id (SWAP_DIRECT_*)
    value - order max value in TON nanoCRYSTALS
    minValue - order minimum value in TON nanoCRYSTALS
    exchangeRate - exchange rate
    timeLockSlot - Time lock slot is seconds
    secretHash - sha256 of secret
    initiatorTargetAddress - initiator foreign token target address
  */
  function createDirectOrder(uint32 dbId,
              uint256 value,
              uint256 minValue,
              uint256 exchangeRate,
              uint32 timeLockSlot,
              bytes32 secretHash,
              uint256 initiatorTargetAddress) external {

    // limit timeLockSlot to prevent time overflow attacks
    require(timeLockSlot >= uint32(TIMELOCK_MIN) && timeLockSlot <= uint32(TIMELOCK_MAX), ERROR_INVALID_TIME_LOCK_SLOT);
    // prevent some stupid errors
    require(value > uint256(0), ERROR_INVALID_VALUE);
    require(minValue > uint256(0) && minValue <= value, ERROR_INVALID_MIN_VALUE);
    require(exchangeRate != uint256(0), ERROR_INVALID_EXCHANGE_RATE);
    require(initiatorTargetAddress != uint256(0), ERROR_INVALID_FOREIGN_ADDRESS);
    
    address sender = msg.sender;
  
    // Check swap DB existence
    require(dbId < SWAP_DIRECT_MAX, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapDirectDB[dbId].orders.exists(sender);
    // and fail if already exists
    require(!orderExists, ERROR_INVALID_ORDER_EXISTS);
  
    // Search for participant balance
    bool balanceExists = participantDB.exists(sender);
    // Check if it exists and participant has sufficient balance
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance balance = participantDB[sender];
    require(value <= balance.value, ERROR_USER_INSUFFICIENT_BALANCE);
    
    // Create new order
    SwapDirectOrder newOrder;
    
    // new order is not confirmed
    newOrder.confirmed = false;
    // order max value in TON nanoCRYSTALS
    newOrder.value = value;
    // order minimum value in TON nanoCRYSTALS
    newOrder.minValue = minValue;
    // Exchange rate
    newOrder.exchangeRate = exchangeRate;
    // Time lock slot is seconds
    newOrder.timeLockSlot = timeLockSlot;
    // hash(secret)
    newOrder.secretHash = secretHash;
    // initiator Foreign token target Address
    newOrder.initiatorTargetAddress = initiatorTargetAddress;

    // add order to DB
    swapDirectDB[dbId].orders.add(sender, newOrder);
    
    // Update initiator balance
    balance.value -= value;
    balance.inOrders = add256(balance.inOrders, value);
    participantDB[sender] = balance;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Delete unconfirmed direct order
    
    dbId - swap direction id (SWAP_DIRECT_*)
  */
  function deleteDirectOrder(uint32 dbId) external {

    address sender = msg.sender;
  
    // Check swap DB existence
    require(dbId < swapDirectDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapDirectDB[dbId].orders.exists(sender);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapDirectOrder order = swapDirectDB[dbId].orders[sender];
    // fail if order already confirmed
    require(!order.confirmed, ERROR_INVALID_ORDER_CONFIRMED);
  
    // Search for participant balance
    bool balanceExists = participantDB.exists(sender);
    // Check if it exists
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance balance = participantDB[sender];
    
    // Update participant balances
    balance.value = add256(balance.value, order.value);
    require(balance.inOrders >= order.value, ERROR_SUB_OVERFLOW);
    balance.inOrders -= order.value;
    participantDB[sender] = balance;
    
    // Delete order
    SwapDirectDB db = swapDirectDB[dbId];
    delete db.orders[sender];
    swapDirectDB[dbId] = db;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Confirm existing direct order
    Initiator funds are locked from this moment

    dbId - swap direction id (SWAP_DIRECT_*)
    value - order actual value in TON nanoCRYSTALS
    initiatorAddress - order initiator address
    confirmatorSourceAddress - confirmator Foreign token source address
  */
  function confirmDirectOrder(uint32 dbId,
              uint256 value,
              address initiatorAddress,
              uint256 confirmatorSourceAddress) external {

    require(value > uint256(0), ERROR_INVALID_VALUE);
    require(initiatorAddress != address(0), ERROR_INVALID_ADDRESS);
    require(confirmatorSourceAddress != uint256(0), ERROR_INVALID_FOREIGN_ADDRESS);
  
    // Check swap DB existence
    require(dbId < swapDirectDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapDirectDB[dbId].orders.exists(initiatorAddress);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapDirectOrder order = swapDirectDB[dbId].orders[initiatorAddress];
    // fail if order already confirmed
    require(!order.confirmed, ERROR_INVALID_ORDER_CONFIRMED);
    // check value range
    require(value >= order.minValue && value <= order.value, ERROR_VALUE_RANGE);
  
    // Search for initiator balance
    bool balanceExists = participantDB.exists(initiatorAddress);
    // Check if it exists
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance initiatorBalance = participantDB[initiatorAddress];
    
    // Update initiator balances
    // Return the remainder to the initiator
    uint256 delta = order.value - value;
    // Funds transfer from `inOrders` to `locked` and `value`
    require(initiatorBalance.inOrders >= order.value, ERROR_SUB_OVERFLOW);
    initiatorBalance.inOrders -= order.value;
    initiatorBalance.locked = add256(initiatorBalance.locked, value);
    initiatorBalance.value = add256(initiatorBalance.value, delta);
    participantDB[initiatorAddress] = initiatorBalance;
    
    // update exchange value
    order.value = value;
    
    // Confirmator TON address
    order.confirmatorTargetAddress = msg.sender;
    // Confirmator Foreign token source Address
    order.confirmatorSourceAddress = confirmatorSourceAddress;
    // Save current time
    order.confirmTime = uint32(now);
    // Confirm order
    order.confirmed = true;
    
    // update order in DB
    swapDirectDB[dbId].orders.replace(initiatorAddress, order);
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Finish direct order with secret
    Confirmator gets TON CRYSTALS
    
    dbId - swap direction id (SWAP_DIRECT_*)
    initiatorAddress - order initiator address
    secret - secret to unlock funds
  */
  function finishDirectOrderWithSecret(uint32 dbId,
              address initiatorAddress,
              bytes secret) external {
    
    require(initiatorAddress != address(0), ERROR_INVALID_ADDRESS);
    
    // Check swap DB existence
    require(dbId < swapDirectDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapDirectDB[dbId].orders.exists(initiatorAddress);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapDirectOrder order = swapDirectDB[dbId].orders[initiatorAddress];
    // fail if order not confirmed
    require(order.confirmed, ERROR_INVALID_ORDER_NOT_CONFIRMED);
    
    // Check secret
    require(sha256(secret) == order.secretHash, ERROR_INVALID_SECRET);
    
    // Search for initiator balance
    bool balanceExists = participantDB.exists(initiatorAddress);
    // Check if it exists
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance initiatorBalance = participantDB[initiatorAddress];
    
    // Update initiator balances
    require(initiatorBalance.locked >= order.value, ERROR_SUB_OVERFLOW);
    initiatorBalance.locked -= order.value;
    participantDB[initiatorAddress] = initiatorBalance;
    
    address confirmatorAddress = order.confirmatorTargetAddress;
  
    // Get confirmator address if exists
    bool confirmatorExists = participantDB.exists(confirmatorAddress);
    if (confirmatorExists) {
      ParticipantBalance confirmatorBalance = participantDB[confirmatorAddress];

      // Increase confirmator balance
      confirmatorBalance.value = add256(confirmatorBalance.value, order.value);
      
      // update DB record
      participantDB[confirmatorAddress] = confirmatorBalance;
      
    } else {
      // Create new DB record
      participantDB[confirmatorAddress] = ParticipantBalance({value:order.value, inOrders:uint256(0), locked:uint256(0)});
    }
    
    // Delete order
    SwapDirectDB db = swapDirectDB[dbId];
    delete db.orders[initiatorAddress];
    swapDirectDB[dbId] = db;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Finish direct order with timeout
    Initiator gets TON CRYSTALS back
    
    dbId - swap direction id (SWAP_DIRECT_*)
    initiatorAddress - order initiator address
  */
  function finishDirectOrderWithTimeout(uint32 dbId,
              address initiatorAddress) external {
    
    require(initiatorAddress != address(0), ERROR_INVALID_ADDRESS);
    
    // Check swap DB existence
    require(dbId < swapDirectDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapDirectDB[dbId].orders.exists(initiatorAddress);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapDirectOrder order = swapDirectDB[dbId].orders[initiatorAddress];
    // fail if order not confirmed
    require(order.confirmed, ERROR_INVALID_ORDER_NOT_CONFIRMED);
    
    // Check time expiration
    uint32 expireAt = order.confirmTime + 3 * order.timeLockSlot;
    require(expireAt < uint32(now), ERROR_NOT_EXPIRED);
    
    // Search for initiator balance
    bool balanceExists = participantDB.exists(initiatorAddress);
    // Check if it exists
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance initiatorBalance = participantDB[initiatorAddress];
    
    // Update initiator balances
    initiatorBalance.value = add256(initiatorBalance.value, order.value);
    require(initiatorBalance.locked >= order.value, ERROR_SUB_OVERFLOW);
    initiatorBalance.locked -= order.value;
    participantDB[initiatorAddress] = initiatorBalance;
    
    // Delete order
    SwapDirectDB db = swapDirectDB[dbId];
    delete db.orders[initiatorAddress];
    swapDirectDB[dbId] = db;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    REVERSED SWAPS
  */

  /*
    Create order with reversed direction (Alt currency -> Free TON)
    
    dbId - swap direction id (SWAP_REVERSED_*)
    value - order max value in Foreign tokens
    minValue - order minimum value in Foreign tokens
    exchangeRate - exchange rate
    timeLockSlot - Time lock slot is seconds
    initiatorSourceAddress - initiator foreign token source address
  */
  function createReversedOrder(uint32 dbId,
              uint256 value,
              uint256 minValue,
              uint256 exchangeRate,
              uint32 timeLockSlot,
              uint256 initiatorSourceAddress) external {

    // limit timeLockSlot to prevent time overflow attacks
    require(timeLockSlot >= uint32(TIMELOCK_MIN) && timeLockSlot <= uint32(TIMELOCK_MAX), ERROR_INVALID_TIME_LOCK_SLOT);
    // prevent some stupid errors
    require(value > uint256(0), ERROR_INVALID_VALUE);
    require(minValue > uint256(0) && minValue <= value, ERROR_INVALID_MIN_VALUE);
    require(exchangeRate != uint256(0), ERROR_INVALID_EXCHANGE_RATE);
    require(initiatorSourceAddress != uint256(0), ERROR_INVALID_FOREIGN_ADDRESS);
    
    address sender = msg.sender;
    
    // Check swap DB existence
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapReversedDB[dbId].orders.exists(sender);
    // and fail if already exists
    require(!orderExists, ERROR_INVALID_ORDER_EXISTS);
    
      // initiator balance not required
    
    // Create new order
    SwapReversedOrder newOrder;
    
    // new order is not confirmed
    newOrder.confirmed = false;
    // order max value in Foreign tokens (the smallest denomination)
    newOrder.foreignValue = value;
    // order minimum value Foreign tokens (the smallest denomination)
    newOrder.foreignMinValue = minValue;
    // Exchange rate
    // Foreign tokens for 1 TON CRYSTAL (1000000000 nanoCRYSTALS)
    // Foreign tokens is indicated in the smallest denomination (wei for ETH, 0.000001 for USDT, satoshi for BTC, etc)
    newOrder.exchangeRate = exchangeRate;
    // Time lock slot is seconds
    newOrder.timeLockSlot = timeLockSlot;
    // Initiator Foreign token source Address
    newOrder.initiatorSourceAddress = initiatorSourceAddress;
    
    // add order to DB
    swapReversedDB[dbId].orders.add(sender, newOrder);
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Delete unconfirmed reversed order
    
    dbId - swap direction id (SWAP_REVERSED_*)
  */
  function deleteReversedOrder(uint32 dbId) external {

    address sender = msg.sender;
    
    // Check swap DB existence
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapReversedDB[dbId].orders.exists(sender);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapReversedOrder order = swapReversedDB[dbId].orders[sender];
    // fail if order already confirmed
    require(!order.confirmed, ERROR_INVALID_ORDER_CONFIRMED);
    
    // Delete order
    SwapReversedDB db = swapReversedDB[dbId];
    delete db.orders[sender];
    swapReversedDB[dbId] = db;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Confirm existing reversed order
    Confirmator funds are locked from this moment

    dbId - swap direction id (SWAP_REVERSED_*)
    value - order actual value in TON nanoCRYSTALS
    initiatorAddress - order initiator address
    confirmatorTargetAddress - confirmator Foreign token target address
    secretHash - sha256 of secret
  */
  function confirmReversedOrder(uint32 dbId,
              uint256 value,
              address initiatorAddress,
              uint256 confirmatorTargetAddress,
              bytes32 secretHash) external {

    require(value > uint256(0), ERROR_INVALID_VALUE);
    require(initiatorAddress != address(0), ERROR_INVALID_ADDRESS);
    require(confirmatorTargetAddress != uint256(0), ERROR_INVALID_FOREIGN_ADDRESS);
    
    // Check swap DB existence
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapReversedDB[dbId].orders.exists(initiatorAddress);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapReversedOrder order = swapReversedDB[dbId].orders[initiatorAddress];
    // fail if order already confirmed
    require(!order.confirmed, ERROR_INVALID_ORDER_CONFIRMED);
    
    // check confirmator balance
    address sender = msg.sender;
  
    bool balanceExists = participantDB.exists(sender);
    // Check if it exists and confirmator has sufficient balance
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance balance = participantDB[sender];
    require(value <= balance.value, ERROR_USER_INSUFFICIENT_BALANCE);
    
    // convert TON CRYSTALS value to Foreign tokens
    uint256 foreignValue = muldivTon(value, order.exchangeRate);
    // check foreignValue range
    if (dbId == SWAP_REVERSED_ETH_TON) {
      require(foreignValue >= (order.foreignMinValue - ETH_ROUND_EXP) && foreignValue <= (order.foreignValue + ETH_ROUND_EXP), ERROR_VALUE_RANGE);
    } else if (dbId == SWAP_REVERSED_USDT_TON) {
      require(foreignValue >= (order.foreignMinValue - USDT_ROUND_EXP) && foreignValue <= (order.foreignValue + USDT_ROUND_EXP), ERROR_VALUE_RANGE);
    } else if (dbId == SWAP_REVERSED_BTC_TON) {
      require(foreignValue >= (order.foreignMinValue - BTC_ROUND_EXP) && foreignValue <= (order.foreignValue + BTC_ROUND_EXP), ERROR_VALUE_RANGE);
    }
    
    // update order
    
    // Confirmed order value in TON nanoCRYSTALS
    order.value = value;
    // Confirmator TON address
    order.confirmatorSourceAddress = sender;
    // Confirmator Foreign token target Address
    order.confirmatorTargetAddress = confirmatorTargetAddress;
    // hash(secret)
    order.secretHash = secretHash;
    // Save current time
    order.confirmTime = uint32(now);
    // Confirm order
    order.confirmed = true;
    
    // update order in DB
    swapReversedDB[dbId].orders.replace(initiatorAddress, order);
    
    // Update confirmator balance
    balance.value -= value;
    balance.locked = add256(balance.locked, value);
    participantDB[sender] = balance;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Finish reversed order with secret
    Initiator gets TON CRYSTALS
    
    dbId - swap direction id (SWAP_REVERSED_*)
    initiatorAddress - order initiator address
    secret - secret to unlock funds
  */
  function finishReversedOrderWithSecret(uint32 dbId,
              address initiatorAddress,
              bytes secret) external {
    
    require(initiatorAddress != address(0), ERROR_INVALID_ADDRESS);
  
    // Check swap DB existence
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapReversedDB[dbId].orders.exists(initiatorAddress);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapReversedOrder order = swapReversedDB[dbId].orders[initiatorAddress];
    // fail if order not confirmed
    require(order.confirmed, ERROR_INVALID_ORDER_NOT_CONFIRMED);
    
    // Check secret
    require(sha256(secret) == order.secretHash, ERROR_INVALID_SECRET);
  
    // Search for confirmator balance
    bool balanceExists = participantDB.exists(order.confirmatorSourceAddress);
    // Check if it exists
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance confirmatorBalance = participantDB[order.confirmatorSourceAddress];
    
    // Update confirmator balances
    require(confirmatorBalance.locked >= order.value, ERROR_SUB_OVERFLOW);
    confirmatorBalance.locked -= order.value;
    participantDB[order.confirmatorSourceAddress] = confirmatorBalance;
  
    // Get initiator address if exists
    bool initiatorExists = participantDB.exists(initiatorAddress);
    if (initiatorExists) {
      ParticipantBalance initiatorBalance = participantDB[initiatorAddress];

      // Increase initiator balance
      initiatorBalance.value = add256(initiatorBalance.value, order.value);
      
      // update DB record
      participantDB[initiatorAddress] = initiatorBalance;
      
    } else {
      // Create new DB record
      participantDB[initiatorAddress] = ParticipantBalance({value:order.value, inOrders:uint256(0), locked:uint256(0)});
    }
    
    // Delete order
    SwapReversedDB db = swapReversedDB[dbId];
    delete db.orders[initiatorAddress];
    swapReversedDB[dbId] = db;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    Finish reversed order with timeout
    Confirmator gets TON CRYSTALS back
    
    dbId - swap direction id (SWAP_REVERSED_*)
    initiatorAddress - order initiator address
  */
  function finishReversedOrderWithTimeout(uint32 dbId,
              address initiatorAddress) external {
    
    require(initiatorAddress != address(0), ERROR_INVALID_ADDRESS);
    
    // Check swap DB existence
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    
    // Search for existing order
    bool orderExists = swapReversedDB[dbId].orders.exists(initiatorAddress);
    // and fail if not exists
    require(orderExists, ERROR_INVALID_ORDER_NOT_EXISTS);

    SwapReversedOrder order = swapReversedDB[dbId].orders[initiatorAddress];
    // fail if order not confirmed
    require(order.confirmed, ERROR_INVALID_ORDER_NOT_CONFIRMED);
    
    // Check time expiration
    uint32 expireAt = order.confirmTime + 3 * order.timeLockSlot;
    require(expireAt < uint32(now), ERROR_NOT_EXPIRED);
    
    // Search for confirmator balance
    bool balanceExists = participantDB.exists(order.confirmatorSourceAddress);
    // Check if it exists
    require(balanceExists, ERROR_USER_NOT_EXISTS_IN_DB);

    ParticipantBalance confirmatorBalance = participantDB[order.confirmatorSourceAddress];
    
    // Update confirmator balances
    confirmatorBalance.value = add256(confirmatorBalance.value, order.value);
    require(confirmatorBalance.locked >= order.value, ERROR_SUB_OVERFLOW);
    confirmatorBalance.locked -= order.value;
    participantDB[order.confirmatorSourceAddress] = confirmatorBalance;
    
    // Delete order
    SwapReversedDB db = swapReversedDB[dbId];
    delete db.orders[initiatorAddress];
    swapReversedDB[dbId] = db;
    
    // Transfer unspended funds
    // flag = 64 is used for messages that carry all the remaining value of the inbound message
    // in addition to the value initially indicated in the new message (0 in this case)
    // bit 0 is not set, so the gas fees are deducted from this amount
    msg.sender.transfer({value: uint128(0), bounce: false, flag: 64});
  }

  /*
    UTILS and GETTERS
  */

  /* Safe addition */
  function add256(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a, ERROR_ADD_OVERFLOW);

    return c;
  }

  /*
    Used to calculate currency conversion
    res = a*b/1000000000
    Since rounding is possible after division, we limit the minimum amount so that the rounded value is no more than 1% of the exchange amount
  */
  function muldivTon(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a * b;
    require(c >= uint256(100000000000), ERROR_VALUE_ROUNDED);

    return math.muldiv(a, b, uint256(1000000000));
  }

  /*
    Сalculates the exchange of TON CRYSTAL for Foreign tokens (in the smallest denomination)
  */
  function calcForeignOutput(uint256 value, uint256 exchangeRate) public pure returns (uint256 foreignValue) {
    foreignValue = muldivTon(value, exchangeRate);
  }

  /*
    Get all direct orders
  */
  function getDirectOrders(uint32 dbId) view public returns(address[] orders) {
    require(dbId < swapDirectDB.length, ERROR_INVALID_DB);
    optional(address, SwapDirectOrder) minPair = swapDirectDB[dbId].orders.min();
    if (minPair.hasValue()) {
      (address key, SwapDirectOrder value) = minPair.get();
      if (!value.confirmed) {
        orders.push(key);
      }
      while(true) {
        optional(address, SwapDirectOrder) nextPair = swapDirectDB[dbId].orders.next(key);
        if (nextPair.hasValue()) {
          (address nextKey, SwapDirectOrder nextValue) = nextPair.get();
          if (!nextValue.confirmed) {
            orders.push(nextKey);
          }
          key = nextKey;
        } else {
          break;
        }
      }
    }
    return orders;
  }

  /*
    Get all reversed orders
  */
  function getReversedOrders(uint32 dbId) view public returns(address[] orders) {
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    optional(address, SwapReversedOrder) minPair = swapReversedDB[dbId].orders.min();
    if (minPair.hasValue()) {
      (address key, SwapReversedOrder value) = minPair.get();
      if (!value.confirmed) {
        orders.push(key);
      }
      while(true) {
        optional(address, SwapReversedOrder) nextPair = swapReversedDB[dbId].orders.next(key);
        if (nextPair.hasValue()) {
          (address nextKey, SwapReversedOrder nextValue) = nextPair.get();
          if (!nextValue.confirmed) {
            orders.push(nextKey);
          }
          key = nextKey;
        } else {
          break;
        }
      }
    }
    return orders;
  }

  /*
    Get direct order info
  */
  function getDirectOrder(uint32 dbId, address initiatorAddress) view public returns (SwapDirectOrder order) {
    require(dbId < swapDirectDB.length, ERROR_INVALID_DB);
    order = swapDirectDB[dbId].orders[initiatorAddress];
  }

  /*
    Get reversed order info
  */
  function getReversedOrder(uint32 dbId, address initiatorAddress) view public returns (SwapReversedOrder order) {
    require(dbId < swapReversedDB.length, ERROR_INVALID_DB);
    order = swapReversedDB[dbId].orders[initiatorAddress];
  }

  function getHash(bytes secret) pure public returns (bytes32 hash) {
    hash = sha256(secret);
  }

}
