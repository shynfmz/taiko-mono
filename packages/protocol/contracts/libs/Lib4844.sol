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

/// @title Lib4844
/// @custom:security-contact security@taiko.xyz
/// @notice A library for handling EIP-4844 blobs
/// `solc contracts/libs/Lib4844.sol --ir > contracts/libs/Lib4844.yul`
library Lib4844 {
    address public constant POINT_EVALUATION_PRECOMPILE_ADDRESS = address(0x0A);
    uint32 public constant FIELD_ELEMENTS_PER_BLOB = 4096;
    uint256 public constant BLS_MODULUS =
        52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513;

    error EVAL_FAILED_1();
    error EVAL_FAILED_2();
    error POINT_X_TOO_LARGE();
    error POINT_Y_TOO_LARGE();

    /// @notice Evaluates the 4844 point using the precompile.
    /// @param _blobHash The versioned hash
    /// @param _x The evaluation point
    /// @param _y The expected output
    /// @param _commitment The input kzg point
    /// @param _pointProof The quotient kzg
    function evaluatePoint(
        bytes32 _blobHash,
        uint256 _x,
        uint256 _y,
        bytes1[48] memory _commitment,
        bytes1[48] memory _pointProof
    )
        internal
        view
    {
        if (_x >= BLS_MODULUS) revert POINT_X_TOO_LARGE();
        if (_y >= BLS_MODULUS) revert POINT_Y_TOO_LARGE();

        (bool ok, bytes memory ret) = POINT_EVALUATION_PRECOMPILE_ADDRESS.staticcall(
            abi.encodePacked(_blobHash, _x, _y, _commitment, _pointProof)
        );

        if (!ok) revert EVAL_FAILED_1();

        if (ret.length != 64) revert EVAL_FAILED_2();

        bytes32 first;
        bytes32 second;
        assembly {
            first := mload(add(ret, 32))
            second := mload(add(ret, 64))
        }
        if (uint256(first) != FIELD_ELEMENTS_PER_BLOB || uint256(second) != BLS_MODULUS) {
            revert EVAL_FAILED_2();
        }
    }
}
