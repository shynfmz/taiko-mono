// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/
//
//   Email: security@taiko.xyz
//   Website: https://taiko.xyz
//   GitHub: https://github.com/taikoxyz
//   Discord: https://discord.gg/taikoxyz
//   Twitter: https://twitter.com/taikoxyz
//   Blog: https://mirror.xyz/labs.taiko.eth
//   Youtube: https://www.youtube.com/@taikoxyz

pragma solidity 0.8.24;

import "./IAddressManager.sol";
import "./EssentialContract.sol";

/// @title AddressManager
/// @custom:security-contact security@taiko.xyz
/// @notice Manages a mapping of chainId-name pairs to Ethereum addresses.
contract AddressManager is EssentialContract, IAddressManager {
    mapping(uint256 chainId => mapping(bytes32 name => address addr)) private addresses;
    uint256[49] private __gap;

    event AddressSet(
        uint64 indexed chainId, bytes32 indexed name, address newAddress, address oldAddress
    );

    error AM_INVALID_PARAMS();
    error AM_UNSUPPORTED();

    /// @notice Initializes the contract.
    /// @param _owner The owner of this contract. msg.sender will be used if this value is zero.
    function init(address _owner) external initializer {
        __Essential_init(_owner);
    }

    /// @notice Sets the address for a specific chainId-name pair.
    /// @param _chainId The chainId to which the address will be mapped.
    /// @param _name The name to which the address will be mapped.
    /// @param _newAddress The Ethereum address to be mapped.
    function setAddress(
        uint64 _chainId,
        bytes32 _name,
        address _newAddress
    )
        external
        virtual
        onlyOwner
    {
        address oldAddress = addresses[_chainId][_name];
        if (_newAddress == oldAddress) revert AM_INVALID_PARAMS();
        addresses[_chainId][_name] = _newAddress;
        emit AddressSet(_chainId, _name, _newAddress, oldAddress);
    }

    /// @inheritdoc IAddressManager
    function getAddress(uint64 _chainId, bytes32 _name) public view override returns (address) {
        return addresses[_chainId][_name];
    }

    function _authorizePause(address) internal pure override {
        revert AM_UNSUPPORTED();
    }
}
