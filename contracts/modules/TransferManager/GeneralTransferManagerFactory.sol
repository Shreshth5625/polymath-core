pragma solidity ^0.4.18;

import './GeneralTransferManager.sol';
import '../../interfaces/IModuleFactory.sol';

contract GeneralTransferManagerFactory is IModuleFactory {

  function deploy(bytes /* _data */) external returns(address) {
    //polyToken.transferFrom(msg.sender, owner, getCost());
    return address(new GeneralTransferManager(msg.sender));
  }

  function getCost() view external returns(uint256) {
    return 0;
  }

  function getType() view external returns(uint8) {
      return 2;
  }

  function getName() view external returns(bytes32) {
    return "GeneralTransferManager";
  }

  function getDescription() view external returns(string) {
    return "Manage transfers using a time based whitelist";
  }

  function getTitle() view external returns(string) {
    return "General Transfer Manager";
  }

}
