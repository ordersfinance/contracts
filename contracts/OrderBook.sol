// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import './interface/IBEP20.sol';
import './libs/SafeBEP20.sol';

contract OrderBook {
  using SafeBEP20 for IBEP20;

  struct Order {
    uint256 id;
    address maker;
    uint256 price;
    uint256 amount;
  }

  uint256 public orderCount = 0;
  mapping(IBEP20 => mapping(IBEP20 => Order[])) public orders;
  mapping(IBEP20 => mapping(IBEP20 => mapping(uint256 => uint256))) public orderIndex;
  address public feeTo;
  address public feeToSetter;

  uint private unlocked = 1;

  address private constant BNB = address(0);

  event OpenOrder(IBEP20 baseToken, IBEP20 quoteToken, uint256 price, uint256 amount);
  event CancelOrder(IBEP20 baseToken, IBEP20 quoteToken, uint256 orderId);
  event ExecuteOrder(IBEP20 baseToken, IBEP20 quoteToken, uint256 orderId, uint256 amount);

  modifier lock() {
    require(unlocked == 1, 'Pancake: LOCKED');
    unlocked = 0;
    _;
    unlocked = 1;
  }

  constructor (address _feeToSetter) {
    feeToSetter = _feeToSetter;
  }

  function getPairOrders (IBEP20 _baseToken, IBEP20 _quoteToken) external view returns (Order[] memory) {
    return orders[_baseToken][_quoteToken];
  }

  function openOrder (
    IBEP20 _baseToken,
    IBEP20 _quoteToken,
    uint256 _price,
    uint256 _amount
  ) external payable lock returns (uint256 orderId) {
    require(_price > 0, 'Price must be > 0');
    require(_amount > 0, 'Amount must be > 0');

    if (address(_baseToken) == BNB) {
      require(msg.value == _amount, 'Incorrect amount paid');
    } else {
      _baseToken.safeTransferFrom(address(msg.sender), address(this), _amount);
    }

    orderCount++;

    // Using the first element of the index can cause inconsistencies
    if (orders[_baseToken][_quoteToken].length == 0) {
      orders[_baseToken][_quoteToken].push();
    }

    Order memory order;
    order.id = orderCount;
    order.maker = msg.sender;
    order.price = _price;
    order.amount = _amount;
    orders[_baseToken][_quoteToken].push(order);
    orderIndex[_baseToken][_quoteToken][order.id] = orders[_baseToken][_quoteToken].length - 1;

    emit OpenOrder(_baseToken, _quoteToken, _price, _amount);

    return order.id;
  }

  function cancelOrder (
    IBEP20 _baseToken,
    IBEP20 _quoteToken,
    uint256 _orderId
  ) external lock {
    uint256 index = orderIndex[_baseToken][_quoteToken][_orderId];
    Order memory order = orders[_baseToken][_quoteToken][index];
    require(order.maker == address(msg.sender), 'Not allowed');

    deleteOrder(_baseToken, _quoteToken, _orderId);
    safePay(_baseToken, address(msg.sender), order.amount);

    emit CancelOrder(_baseToken, _quoteToken, _orderId);
  }

  function executeOrder (
    IBEP20 _baseToken,
    IBEP20 _quoteToken,
    uint256 _orderId,
    uint256 _amount
  ) external payable lock {
    require(_amount > 0, 'Amount must be greater than 0');

    uint256 index = orderIndex[_baseToken][_quoteToken][_orderId];
    Order storage order = orders[_baseToken][_quoteToken][index];
    uint256 amount = _amount > order.amount ? order.amount : _amount;

    // token prices are always expressed with 18 decimals
    uint256 payAmount = amount * order.price / 10**18;

    uint feeAmount = payAmount / 500;
    bool feeOn = feeTo != address(0);

    if (address(_quoteToken) == BNB) {
      if (feeOn) {
        require(msg.value == payAmount + feeAmount, 'Incorrect amount paid');
        payable(feeTo).transfer(feeAmount);
      } else {
        require(msg.value == payAmount, 'Incorrect amount paid');
      }
      payable(address(order.maker)).transfer(payAmount);
    } else {
      if (feeOn) {
        _quoteToken.safeTransferFrom(address(msg.sender), feeTo, feeAmount);
      }
      _quoteToken.safeTransferFrom(address(msg.sender), address(order.maker), payAmount);
    }

    if (amount == order.amount) { // Full fill
      deleteOrder(_baseToken, _quoteToken, _orderId);
    } else { // Partial fill
      order.amount -= amount;
    }

    safePay(_baseToken, address(msg.sender), amount);

    emit ExecuteOrder(_baseToken, _quoteToken, _orderId, _amount);
  }

  function deleteOrder (
    IBEP20 _baseToken,
    IBEP20 _quoteToken,
    uint _orderId
  ) private {
    uint256 index = orderIndex[_baseToken][_quoteToken][_orderId];
    delete orderIndex[_baseToken][_quoteToken][_orderId];
    Order memory lastOrder = orders[_baseToken][_quoteToken][orders[_baseToken][_quoteToken].length - 1];
    if (lastOrder.id != _orderId) {
      orderIndex[_baseToken][_quoteToken][lastOrder.id] = index;
      orders[_baseToken][_quoteToken][index] = lastOrder;
    }
    orders[_baseToken][_quoteToken].pop();
  }

  function safePay (IBEP20 token, address to, uint256 amount) private {
    if (address(token) == BNB) { // Transfer BNB
      payable(to).transfer(amount);
    } else { // Transfer BEP20 token
      token.approve(address(this), amount);
      token.safeTransferFrom(address(this), to, amount);
    }
  }

  function setFeeTo(address _feeTo) external {
    require(msg.sender == feeToSetter, 'Forbidden');
    feeTo = _feeTo;
  }

  function setFeeToSetter(address _feeToSetter) external {
    require(msg.sender == feeToSetter, 'Forbidden');
    feeToSetter = _feeToSetter;
  }
}
