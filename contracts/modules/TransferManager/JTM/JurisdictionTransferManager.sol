pragma solidity ^0.5.0;

import "../TransferManager.sol";
import "../../../libraries/Encoder.sol";
import "../../../libraries/VersionUtils.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/cryptography/ECDSA.sol";
import "./JurisdictionManagerStorage.sol";

/**
 * @title Transfer Manager module for core transfer validation functionality
 */
contract JurisdictionTransferManager is JurisdictionTransferManagerStorage, TransferManager {
    using SafeMath for uint256;
    using ECDSA for bytes32;

    // _canSendAfter is the time from which the _investor can send tokens
    // _canReceiveAfter is the time from which the _investor can receive tokens
    // if allowAllWhitelistIssuances is TRUE, then _canReceiveAfter is ignored when receiving tokens from the issuance address
    // if allowAllWhitelistTransfers is TRUE, then _canReceiveAfter and _canSendAfter is ignored when sending or receiving tokens
    // in any case, any investor sending or receiving tokens, must have a _expiryTime in the future
    event ModifyJurisdictionData(
        address indexed _investor,
        address indexed _addedBy,
        bytes32 _jurisdiction
    );

    /**
     * @notice Constructor
     * @param _securityToken Address of the security token
     */
    constructor(address _securityToken, address _polyToken)
    public
    Module(_securityToken, _polyToken)
    {

    }

    /**
     * @notice This function returns the signature of configure function
     */
    function getInitFunction() public pure returns(bytes4) {
        return bytes4(0);
    }

    /**
     * @notice Default implementation of verifyTransfer used by SecurityToken
     * If the transfer request comes from the STO, it only checks that the investor is in the whitelist
     * If the transfer request comes from a token holder, it checks that:
     * a) Both are on the whitelist
     * b) Seller's sale lockup period is over
     * c) Buyer's purchase lockup is over
     * @param _from Address of the sender
     * @param _to Address of the receiver
    */
    function executeTransfer(
        address _from,
        address _to,
        uint256 /*_amount*/,
        bytes calldata _data
    ) external returns(Result) {
        if (_data.length > 32) {
            address target;
            uint256 nonce;
            uint256 validFrom;
            uint256 validTo;
            bytes memory data;
            (target, nonce, validFrom, validTo, data) = abi.decode(_data, (address, uint256, uint256, uint256, bytes));
            if (target == address(this))
                _processTransferSignature(nonce, validFrom, validTo, data);
        }
        (Result success,) = _verifyTransfer(_from, _to);
        return success;
    }

    /**
     * @notice Default implementation of verifyTransfer used by SecurityToken
     * @param _from Address of the sender
     * @param _to Address of the receiver
    */
    function verifyTransfer(
        address _from,
        address _to,
        uint256 /*_amount*/,
        bytes memory /* _data */
    )
        public
        view
        returns(Result, bytes32)
    {
        return _verifyTransfer(_from, _to);
    }

    function _verifyTransfer(
        address _from,
        address _to
    )
        internal
        view
        returns(Result, bytes32)
    {
        if (!paused) {
            TransferRequirements memory txReq;
            uint64 canSendAfter;
            uint64 fromExpiry;
            uint64 toExpiry;
            uint64 canReceiveAfter;

            if (_from == issuanceAddress) {
                txReq = transferRequirements[uint8(TransferType.ISSUANCE)];
            } else if (_to == address(0)) {
                txReq = transferRequirements[uint8(TransferType.REDEMPTION)];
            } else {
                txReq = transferRequirements[uint8(TransferType.GENERAL)];
            }

            (canSendAfter, fromExpiry, canReceiveAfter, toExpiry) = _getValuesForTransfer(_from, _to);

            if ((txReq.fromValidKYC && !_validExpiry(fromExpiry)) || (txReq.toValidKYC && !_validExpiry(toExpiry))) {
                return (Result.NA, bytes32(0));
            }

            (canSendAfter, canReceiveAfter) = _adjustTimes(canSendAfter, canReceiveAfter);

            if ((txReq.fromRestricted && !_validLockTime(canSendAfter)) || (txReq.toRestricted && !_validLockTime(canReceiveAfter))) {
                return (Result.NA, bytes32(0));
            }

            return (Result.VALID, getAddressBytes32());
        }
        return (Result.NA, bytes32(0));
    }

    /**
    * @notice Add or remove KYC info of an investor.
    * @param _investor is the address to whitelist
    * @param _jurisdiction jurisdiction of investor
    */
    function modifyJurisdictionData(
        address _investor,
        bytes32 _jurisdiction
    )
        public
        withPerm(ADMIN)
    {
        _modifyJurisdictionData(_investor, _jurisdiction);
    }

    function _modifyJurisdictionData(address _investor, bytes32 _jurisdiction) internal {
        require(_investor != address(0), "Invalid investor");
        IDataStore dataStore = getDataStore();
        if (!_isExistingInvestor(_investor, dataStore)) {
           dataStore.insertAddress(INVESTORSKEY, _investor);
        }
        dataStore.setBytes32(_getKey(JURISDICTION, _investor), _jurisdiction);
        emit ModifyJurisdictionData(_investor, msg.sender, _jurisdiction);
    }

    /**
    * @notice Add or remove KYC info of an investor.
    * @param _investors is the address to whitelist
    * @param _jurisdictions jurisdictions of investors
    */
    function modifyJurisdictionDataMulti(
        address[] memory _investors,
        uint64[] memory _jurisdictions
    )
        public
        withPerm(ADMIN)
    {
        require(
            _investors.length == _jurisdictions.length,
            "Mismatched input lengths"
        );
        for (uint256 i = 0; i < _investors.length; i++) {
            _modifyJurisdictionData(_investors[i], _jurisdictions[i]);
        }
    }

    /**
    * @notice Used to modify investor Flag.
    * @dev Flags are properties about investors that can be true or false like isAccredited
    * @param _investor is the address of the investor.
    * @param _flag index of flag to change. flag is used to know specifics about investor like isAccredited.
    * @param _value value of the flag. a flag can be true or false.
    */
    function modifyInvestorFlag(
        address _investor,
        uint8 _flag,
        bool _value
    )
        public
        withPerm(ADMIN)
    {
        _modifyInvestorFlag(_investor, _flag, _value);
    }


    function _modifyInvestorFlag(address _investor, uint8 _flag, bool _value) internal {
        require(_investor != address(0), "Invalid investor");
        IDataStore dataStore = getDataStore();
        if (!_isExistingInvestor(_investor, dataStore)) {
           dataStore.insertAddress(INVESTORSKEY, _investor);
           //KYC data can not be present if _isExistingInvestor is false and hence we can set packed KYC as uint256(1) to set `added` as true
           dataStore.setUint256(_getKey(WHITELIST, _investor), uint256(1));
        }
        //NB Flags are packed together in a uint256 to save gas. We can have a maximum of 256 flags.
        uint256 flags = dataStore.getUint256(_getKey(INVESTORFLAGS, _investor));
        if (_value)
            flags = flags | (ONE << _flag);
        else
            flags = flags & ~(ONE << _flag);
        dataStore.setUint256(_getKey(INVESTORFLAGS, _investor), flags);
        emit ModifyInvestorFlag(_investor, _flag, _value);
    }

    /**
    * @notice Used to modify investor data.
    * @param _investors List of the addresses to modify data about.
    * @param _flag index of flag to change. flag is used to know specifics about investor like isAccredited.
    * @param _value value of the flag. a flag can be true or false.
    */
    function modifyInvestorFlagMulti(
        address[] memory _investors,
        uint8[] memory _flag,
        bool[] memory _value
    )
        public
        withPerm(ADMIN)
    {
        require(
            _investors.length == _flag.length &&
            _flag.length == _value.length,
            "Mismatched input lengths"
        );
        for (uint256 i = 0; i < _investors.length; i++) {
            _modifyInvestorFlag(_investors[i], _flag[i], _value[i]);
        }
    }

    /**
    * @notice Adds or removes addresses from the whitelist - can be called by anyone with a valid signature
    * @param _investor is the address to whitelist
    * @param _canSendAfter is the moment when the sale lockup period ends and the investor can freely sell his tokens
    * @param _canReceiveAfter is the moment when the purchase lockup period ends and the investor can freely purchase tokens from others
    * @param _expiryTime is the moment till investors KYC will be validated. After that investor need to do re-KYC
    * @param _validFrom is the time that this signature is valid from
    * @param _validTo is the time that this signature is valid until
    * @param _nonce nonce of signature (avoid replay attack)
    * @param _signature issuer signature
    */
    function modifyKYCDataSigned(
        address _investor,
        uint256 _canSendAfter,
        uint256 _canReceiveAfter,
        uint256 _expiryTime,
        uint256 _validFrom,
        uint256 _validTo,
        uint256 _nonce,
        bytes memory _signature
    )
        public
    {
        require(
            _modifyKYCDataSigned(_investor, _canSendAfter, _canReceiveAfter, _expiryTime, _validFrom, _validTo, _nonce, _signature),
            "Invalid signature or data"
        );
    }

    function _modifyKYCDataSigned(
        address _investor,
        uint256 _canSendAfter,
        uint256 _canReceiveAfter,
        uint256 _expiryTime,
        uint256 _validFrom,
        uint256 _validTo,
        uint256 _nonce,
        bytes memory _signature
    )
        internal
        returns(bool)
    {
        /*solium-disable-next-line security/no-block-members*/
        if(_validFrom > now || _validTo < now || _investor == address(0))
            return false;
        bytes32 hash = keccak256(
            abi.encodePacked(this, _investor, _canSendAfter, _canReceiveAfter, _expiryTime, _validFrom, _validTo, _nonce)
        );
        if (_checkSig(hash, _signature, _nonce)) {
            require(
                uint64(_canSendAfter) == _canSendAfter &&
                uint64(_canReceiveAfter) == _canReceiveAfter &&
                uint64(_expiryTime) == _expiryTime,
                "uint64 overflow"
            );
            _modifyKYCData(_investor, uint64(_canSendAfter), uint64(_canReceiveAfter), uint64(_expiryTime));
            return true;
        }
        return false;
    }

    /**
    * @notice Adds or removes addresses from the whitelist - can be called by anyone with a valid signature
    * @dev using uint256 for some uint256 variables as web3 wasn;t packing and hashing uint64 arrays properly
    * @param _investor is the address to whitelist
    * @param _canSendAfter is the moment when the sale lockup period ends and the investor can freely sell his tokens
    * @param _canReceiveAfter is the moment when the purchase lockup period ends and the investor can freely purchase tokens from others
    * @param _expiryTime is the moment till investors KYC will be validated. After that investor need to do re-KYC
    * @param _validFrom is the time that this signature is valid from
    * @param _validTo is the time that this signature is valid until
    * @param _nonce nonce of signature (avoid replay attack)
    * @param _signature issuer signature
    */
    function modifyKYCDataSignedMulti(
        address[] memory _investor,
        uint256[] memory _canSendAfter,
        uint256[] memory _canReceiveAfter,
        uint256[] memory _expiryTime,
        uint256 _validFrom,
        uint256 _validTo,
        uint256 _nonce,
        bytes memory _signature
    )
        public
    {
        require(
            _modifyKYCDataSignedMulti(_investor, _canSendAfter, _canReceiveAfter, _expiryTime, _validFrom, _validTo, _nonce, _signature),
            "Invalid signature or data"
        );
    }

    function _modifyKYCDataSignedMulti(
        address[] memory _investor,
        uint256[] memory _canSendAfter,
        uint256[] memory _canReceiveAfter,
        uint256[] memory _expiryTime,
        uint256 _validFrom,
        uint256 _validTo,
        uint256 _nonce,
        bytes memory _signature
    )
        internal
        returns(bool)
    {
        if (_investor.length != _canSendAfter.length ||
            _canSendAfter.length != _canReceiveAfter.length ||
            _canReceiveAfter.length != _expiryTime.length
        ) {
            return false;
        }

        if (_validFrom > now || _validTo < now) {
            return false;
        }

        bytes32 hash = keccak256(
            abi.encodePacked(this, _investor, _canSendAfter, _canReceiveAfter, _expiryTime, _validFrom, _validTo, _nonce)
        );

        if (_checkSig(hash, _signature, _nonce)) {
            for (uint256 i = 0; i < _investor.length; i++) {
                if (uint64(_canSendAfter[i]) == _canSendAfter[i] &&
                    uint64(_canReceiveAfter[i]) == _canReceiveAfter[i] &&
                    uint64(_expiryTime[i]) == _expiryTime[i]
                )
                    _modifyKYCData(_investor[i], uint64(_canSendAfter[i]), uint64(_canReceiveAfter[i]), uint64(_expiryTime[i]));
            }
            return true;
        }
        return false;
    }

    /**
     * @notice Used to verify the signature
     */
    function _checkSig(bytes32 _hash, bytes memory _signature, uint256 _nonce) internal returns(bool) {
        //Check that the signature is valid
        //sig should be signing - _investor, _canSendAfter, _canReceiveAfter & _expiryTime and be signed by the issuer address
        address signer = _hash.toEthSignedMessageHash().recover(_signature);
        if (nonceMap[signer][_nonce] || !_checkPerm(OPERATOR, signer)) {
            return false;
        }
        nonceMap[signer][_nonce] = true;
        return true;
    }

    /**
     * @notice Internal function used to check whether the KYC of investor is valid
     * @param _expiryTime Expiry time of the investor
     */
    function _validExpiry(uint64 _expiryTime) internal view returns(bool valid) {
        if (_expiryTime >= uint64(now)) /*solium-disable-line security/no-block-members*/
            valid = true;
    }

    /**
     * @notice Internal function used to check whether the lock time of investor is valid
     * @param _lockTime Lock time of the investor
     */
    function _validLockTime(uint64 _lockTime) internal view returns(bool valid) {
        if (_lockTime <= uint64(now)) /*solium-disable-line security/no-block-members*/
            valid = true;
    }

    /**
     * @notice Internal function to adjust times using default values
     */
    function _adjustTimes(uint64 _canSendAfter, uint64 _canReceiveAfter) internal view returns(uint64, uint64) {
        if (_canSendAfter == 0) {
            _canSendAfter = defaults.canSendAfter;
        }
        if (_canReceiveAfter == 0) {
            _canReceiveAfter = defaults.canReceiveAfter;
        }
        return (_canSendAfter, _canReceiveAfter);
    }

    function _getKey(bytes32 _key1, address _key2) internal pure returns(bytes32) {
        return bytes32(keccak256(abi.encodePacked(_key1, _key2)));
    }

    function _getKYCValues(address _investor, IDataStore dataStore) internal view returns(
        uint64 canSendAfter,
        uint64 canReceiveAfter,
        uint64 expiryTime,
        uint8 added
    )
    {
        uint256 data = dataStore.getUint256(_getKey(WHITELIST, _investor));
        (canSendAfter, canReceiveAfter, expiryTime, added)  = VersionUtils.unpackKYC(data);
    }

    function _isExistingInvestor(address _investor, IDataStore dataStore) internal view returns(bool) {
        uint256 data = dataStore.getUint256(_getKey(WHITELIST, _investor));
        //extracts `added` from packed `_whitelistData`
        return uint8(data) == 0 ? false : true;
    }

    function _getValuesForTransfer(address _from, address _to) internal view returns(uint64 canSendAfter, uint64 fromExpiry, uint64 canReceiveAfter, uint64 toExpiry) {
        IDataStore dataStore = getDataStore();
        (canSendAfter, , fromExpiry, ) = _getKYCValues(_from, dataStore);
        (, canReceiveAfter, toExpiry, ) = _getKYCValues(_to, dataStore);
    }

    /**
     * @dev Returns list of all investors
     */
    function getAllInvestors() public view returns(address[] memory investors) {
        IDataStore dataStore = getDataStore();
        investors = dataStore.getAddressArray(INVESTORSKEY);
    }

    /**
     * @dev Returns list of investors in a range
     */
    function getInvestors(uint256 _fromIndex, uint256 _toIndex) public view returns(address[] memory investors) {
        IDataStore dataStore = getDataStore();
        investors = dataStore.getAddressArrayElements(INVESTORSKEY, _fromIndex, _toIndex);
    }

    function getAllInvestorFlags() public view returns(address[] memory investors, uint256[] memory flags) {
        investors = getAllInvestors();
        flags = new uint256[](investors.length);
        for (uint256 i = 0; i < investors.length; i++) {
            flags[i] = _getInvestorFlags(investors[i]);
        }
    }

    function getInvestorFlag(address _investor, uint8 _flag) public view returns(bool value) {
        uint256 flag = (_getInvestorFlags(_investor) >> _flag) & ONE;
        value = flag > 0 ? true : false;
    }

    function getInvestorFlags(address _investor) public view returns(uint256 flags) {
        flags = _getInvestorFlags(_investor);
    }

    function _getInvestorFlags(address _investor) public view returns(uint256 flags) {
        IDataStore dataStore = getDataStore();
        flags = dataStore.getUint256(_getKey(INVESTORFLAGS, _investor));
    }

    /**
     * @dev Returns list of all investors data
     */
    function getAllKYCData() external view returns(
        address[] memory investors,
        uint256[] memory canSendAfters,
        uint256[] memory canReceiveAfters,
        uint256[] memory expiryTimes
    ) {
        investors = getAllInvestors();
        (canSendAfters, canReceiveAfters, expiryTimes) = _kycData(investors);
        return (investors, canSendAfters, canReceiveAfters, expiryTimes);
    }

    /**
     * @dev Returns list of specified investors data
     */
    function getKYCData(address[] calldata _investors) external view returns(
        uint256[] memory,
        uint256[] memory,
        uint256[] memory
    ) {
        return _kycData(_investors);
    }

    function _kycData(address[] memory _investors) internal view returns(
        uint256[] memory,
        uint256[] memory,
        uint256[] memory
    ) {
        uint256[] memory canSendAfters = new uint256[](_investors.length);
        uint256[] memory canReceiveAfters = new uint256[](_investors.length);
        uint256[] memory expiryTimes = new uint256[](_investors.length);
        for (uint256 i = 0; i < _investors.length; i++) {
            (canSendAfters[i], canReceiveAfters[i], expiryTimes[i], ) = _getKYCValues(_investors[i], getDataStore());
        }
        return (canSendAfters, canReceiveAfters, expiryTimes);
    }

    /**
     * @notice Return the permissions flag that are associated with general trnasfer manager
     */
    function getPermissions() public view returns(bytes32[] memory) {
        bytes32[] memory allPermissions = new bytes32[](1);
        allPermissions[0] = ADMIN;
        return allPermissions;
    }

    /**
     * @notice return the amount of tokens for a given user as per the partition
     * @param _partition Identifier
     * @param _tokenHolder Whom token amount need to query
     * @param _additionalBalance It is the `_value` that transfer during transfer/transferFrom function call
     */
    function getTokensByPartition(bytes32 _partition, address _tokenHolder, uint256 _additionalBalance) external view returns(uint256) {
        uint256 currentBalance = (msg.sender == securityToken) ? (IERC20(securityToken).balanceOf(_tokenHolder)).add(_additionalBalance) : IERC20(securityToken).balanceOf(_tokenHolder);
        uint256 canSendAfter;
        (canSendAfter,,,) = _getKYCValues(_tokenHolder, getDataStore());
        canSendAfter = (canSendAfter == 0 ? defaults.canSendAfter:  canSendAfter);
        bool unlockedCheck = paused ? _partition == UNLOCKED : (_partition == UNLOCKED && now >= canSendAfter);
        if (((_partition == LOCKED && now < canSendAfter) && !paused) || unlockedCheck)
            return currentBalance;
        else
            return 0;
    }

    function getAddressBytes32() public view returns(bytes32) {
        return bytes32(uint256(address(this)) << 96);
    }

}