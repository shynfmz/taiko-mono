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

import "@openzeppelin/contracts/utils/Address.sol";
import "../common/EssentialContract.sol";
import "../libs/LibAddress.sol";
import "../signal/ISignalService.sol";
import "../thirdparty/nomad-xyz/ExcessivelySafeCall.sol";
import "./IBridge.sol";

/// @title Bridge
/// @custom:security-contact security@taiko.xyz
/// @dev Labeled in AddressResolver as "bridge"
/// @notice See the documentation for {IBridge}.
/// @dev The code hash for the same address on L1 and L2 may be different.
contract Bridge is EssentialContract, IBridge {
    using Address for address;
    using LibAddress for address;
    using LibAddress for address payable;

    enum Status {
        NEW,
        RETRIABLE,
        DONE,
        FAILED,
        RECALLED
    }

    // Note that this struct shall take only 1 slot to minimize gas cost
    struct ProofReceipt {
        // The time a message is marked as received on the destination chain
        uint64 receivedAt;
        // The address that can execute the message after the invocation delay without an extra
        // delay.
        // For a failed message, preferredExecutor's value doesn't matter as only the owner can
        // invoke the message.
        address preferredExecutor;
    }

    // The slot in transient storage of the call context
    // This is the keccak256 hash of "bridge.ctx_slot"
    bytes32 private constant _CTX_SLOT =
        0xe4ece82196de19aabe639620d7f716c433d1348f96ce727c9989a982dbadc2b9;
    // Place holder value when not using transient storage
    uint256 internal constant PLACEHOLDER = type(uint256).max;

    uint128 public nextMessageId; // slot 1
    mapping(bytes32 msgHash => Status status) public messageStatus; // slot 2
    Context private _ctx; // slot 3,4,5
    mapping(address addr => bool banned) public addressBanned; // slot 6
    mapping(bytes32 msgHash => ProofReceipt receipt) public proofReceipt; // slot 7
    uint256[43] private __gap;

    event MessageSent(bytes32 indexed msgHash, Message message);
    event MessageReceived(bytes32 indexed msgHash, Message message, bool isRecall);
    event MessageRecalled(bytes32 indexed msgHash);
    event MessageExecuted(bytes32 indexed msgHash);
    event MessageRetried(bytes32 indexed msgHash);
    event MessageStatusChanged(bytes32 indexed msgHash, Status status);
    event MessageSuspended(bytes32 msgHash, bool suspended);
    event AddressBanned(address indexed addr, bool banned);

    error B_INVALID_CHAINID();
    error B_INVALID_CONTEXT();
    error B_INVALID_GAS_LIMIT();
    error B_INVALID_STATUS();
    error B_INVALID_USER();
    error B_INVALID_VALUE();
    error B_MESSAGE_NOT_SENT();
    error B_NON_RETRIABLE();
    error B_NOT_FAILED();
    error B_NOT_RECEIVED();
    error B_PERMISSION_DENIED();
    error B_STATUS_MISMATCH();
    error B_INVOCATION_TOO_EARLY();

    modifier sameChain(uint64 _chainId) {
        if (_chainId != block.chainid) revert B_INVALID_CHAINID();
        _;
    }

    receive() external payable { }

    /// @notice Initializes the contract.
    /// @param _owner The owner of this contract. msg.sender will be used if this value is zero.
    /// @param _addressManager The address of the {AddressManager} contract.
    function init(address _owner, address _addressManager) external initializer {
        __Essential_init(_owner, _addressManager);
    }

    /// @notice Suspend or unsuspend invocation for a list of messages.
    /// @param _msgHashes The array of msgHashes to be suspended.
    /// @param _toSuspend True if suspend, false if unsuspend.
    function suspendMessages(
        bytes32[] calldata _msgHashes,
        bool _toSuspend
    )
        external
        onlyFromOwnerOrNamed("bridge_watchdog")
    {
        uint64 _timestamp = _toSuspend ? type(uint64).max : uint64(block.timestamp);
        for (uint256 i; i < _msgHashes.length; ++i) {
            bytes32 msgHash = _msgHashes[i];
            proofReceipt[msgHash].receivedAt = _timestamp;
            emit MessageSuspended(msgHash, _toSuspend);
        }
    }

    /// @notice Ban or unban an address. A banned addresses will not be invoked upon
    /// with message calls.
    /// @param _addr The addreess to ban or unban.
    /// @param _toBan True if ban, false if unban.
    function banAddress(
        address _addr,
        bool _toBan
    )
        external
        onlyFromOwnerOrNamed("bridge_watchdog")
        nonReentrant
    {
        if (addressBanned[_addr] == _toBan) revert B_INVALID_STATUS();
        addressBanned[_addr] = _toBan;
        emit AddressBanned(_addr, _toBan);
    }

    /// @notice Sends a message to the destination chain and takes custody
    /// of Ether required in this contract. All extra Ether will be refunded.
    /// @inheritdoc IBridge
    function sendMessage(Message calldata _message)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 msgHash, Message memory message_)
    {
        // Ensure the message owner is not null.
        if (_message.srcOwner == address(0) || _message.destOwner == address(0)) {
            revert B_INVALID_USER();
        }

        // Check if the destination chain is enabled.
        (bool destChainEnabled,) = isDestChainEnabled(_message.destChainId);

        // Verify destination chain and to address.
        if (!destChainEnabled) revert B_INVALID_CHAINID();
        if (_message.destChainId == block.chainid) {
            revert B_INVALID_CHAINID();
        }

        // Ensure the sent value matches the expected amount.
        uint256 expectedAmount = _message.value + _message.fee;
        if (expectedAmount != msg.value) revert B_INVALID_VALUE();

        message_ = _message;
        // Configure message details and send signal to indicate message
        // sending.
        message_.id = nextMessageId++;
        message_.from = msg.sender;
        message_.srcChainId = uint64(block.chainid);

        msgHash = hashMessage(message_);

        ISignalService(resolve("signal_service", false)).sendSignal(msgHash);
        emit MessageSent(msgHash, message_);
    }

    /// @notice Recalls a failed message on its source chain, releasing
    /// associated assets.
    /// @dev This function checks if the message failed on the source chain and
    /// releases associated Ether or tokens.
    /// @param _message The message whose associated Ether should be released.
    /// @param _proof The merkle inclusion proof.
    function recallMessage(
        Message calldata _message,
        bytes calldata _proof
    )
        external
        nonReentrant
        whenNotPaused
        sameChain(_message.srcChainId)
    {
        bytes32 msgHash = hashMessage(_message);

        if (messageStatus[msgHash] != Status.NEW) revert B_STATUS_MISMATCH();

        uint64 receivedAt = proofReceipt[msgHash].receivedAt;
        bool isMessageProven = receivedAt != 0;

        if (!isMessageProven) {
            address signalService = resolve("signal_service", false);

            if (!ISignalService(signalService).isSignalSent(address(this), msgHash)) {
                revert B_MESSAGE_NOT_SENT();
            }

            bytes32 failureSignal = signalForFailedMessage(msgHash);
            if (!_proveSignalReceived(signalService, failureSignal, _message.destChainId, _proof)) {
                revert B_NOT_FAILED();
            }

            receivedAt = uint64(block.timestamp);
            proofReceipt[msgHash].receivedAt = receivedAt;
        }

        // assert(receivedAt != 0);
        (uint256 invocationDelay,) = getInvocationDelays();

        if (block.timestamp >= invocationDelay + receivedAt) {
            delete proofReceipt[msgHash];
            messageStatus[msgHash] = Status.RECALLED;

            // Execute the recall logic based on the contract's support for the
            // IRecallableSender interface
            if (_message.from.supportsInterface(type(IRecallableSender).interfaceId)) {
                _storeContext({
                    _msgHash: msgHash,
                    _from: address(this),
                    _srcChainId: _message.srcChainId
                });

                // Perform recall
                IRecallableSender(_message.from).onMessageRecalled{ value: _message.value }(
                    _message, msgHash
                );

                // Reset the context after the message call
                _resetContext();
            } else {
                _message.srcOwner.sendEther(_message.value);
            }
            emit MessageRecalled(msgHash);
        } else if (!isMessageProven) {
            emit MessageReceived(msgHash, _message, true);
        } else {
            revert B_INVOCATION_TOO_EARLY();
        }
    }

    /// @notice Processes a bridge message on the destination chain. This
    /// function is callable by any address, including the `message.destOwner`.
    /// @dev The process begins by hashing the message and checking the message
    /// status in the bridge  If the status is "NEW", the message is invoked. The
    /// status is updated accordingly, and processing fees are refunded as
    /// needed.
    /// @param _message The message to be processed.
    /// @param _proof The merkle inclusion proof.
    function processMessage(
        Message calldata _message,
        bytes calldata _proof
    )
        external
        nonReentrant
        whenNotPaused
        sameChain(_message.destChainId)
    {
        bytes32 msgHash = hashMessage(_message);
        if (messageStatus[msgHash] != Status.NEW) revert B_STATUS_MISMATCH();

        address signalService = resolve("signal_service", false);
        uint64 receivedAt = proofReceipt[msgHash].receivedAt;
        bool isMessageProven = receivedAt != 0;

        (uint256 invocationDelay, uint256 invocationExtraDelay) = getInvocationDelays();

        if (!isMessageProven) {
            if (!_proveSignalReceived(signalService, msgHash, _message.srcChainId, _proof)) {
                revert B_NOT_RECEIVED();
            }

            receivedAt = uint64(block.timestamp);

            if (invocationDelay != 0) {
                proofReceipt[msgHash] = ProofReceipt({
                    receivedAt: receivedAt,
                    preferredExecutor: _message.gasLimit == 0 ? _message.destOwner : msg.sender
                });
            }
        }

        if (invocationDelay != 0 && msg.sender != proofReceipt[msgHash].preferredExecutor) {
            // If msg.sender is not the one that proved the message, then there
            // is an extra delay.
            unchecked {
                invocationDelay += invocationExtraDelay;
            }
        }

        if (block.timestamp >= invocationDelay + receivedAt) {
            // If the gas limit is set to zero, only the owner can process the message.
            if (_message.gasLimit == 0 && msg.sender != _message.destOwner) {
                revert B_PERMISSION_DENIED();
            }

            delete proofReceipt[msgHash];

            uint256 refundAmount;

            // Process message differently based on the target address
            if (
                _message.to == address(0) || _message.to == address(this)
                    || _message.to == signalService || addressBanned[_message.to]
            ) {
                // Handle special addresses that don't require actual invocation but
                // mark message as DONE
                refundAmount = _message.value;
                _updateMessageStatus(msgHash, Status.DONE);
            } else {
                // Use the specified message gas limit if called by the owner, else
                // use remaining gas
                uint256 gasLimit = msg.sender == _message.destOwner ? gasleft() : _message.gasLimit;

                if (_invokeMessageCall(_message, msgHash, gasLimit)) {
                    _updateMessageStatus(msgHash, Status.DONE);
                } else {
                    _updateMessageStatus(msgHash, Status.RETRIABLE);
                }
            }

            // Determine the refund recipient
            address refundTo =
                _message.refundTo == address(0) ? _message.destOwner : _message.refundTo;

            // Refund the processing fee
            if (msg.sender == refundTo) {
                refundTo.sendEther(_message.fee + refundAmount);
            } else {
                // If sender is another address, reward it and refund the rest
                msg.sender.sendEther(_message.fee);
                refundTo.sendEther(refundAmount);
            }
            emit MessageExecuted(msgHash);
        } else if (!isMessageProven) {
            emit MessageReceived(msgHash, _message, false);
        } else {
            revert B_INVOCATION_TOO_EARLY();
        }
    }

    /// @notice Retries to invoke the messageCall after releasing associated
    /// Ether and tokens.
    /// @dev This function can be called by any address, including the
    /// `message.destOwner`.
    /// It attempts to invoke the messageCall and updates the message status
    /// accordingly.
    /// @param _message The message to retry.
    /// @param _isLastAttempt Specifies if this is the last attempt to retry the
    /// message.
    function retryMessage(
        Message calldata _message,
        bool _isLastAttempt
    )
        external
        nonReentrant
        whenNotPaused
        sameChain(_message.destChainId)
    {
        // If the gasLimit is set to 0 or isLastAttempt is true, the caller must
        // be the message.destOwner.
        if (_message.gasLimit == 0 || _isLastAttempt) {
            if (msg.sender != _message.destOwner) revert B_PERMISSION_DENIED();
        }

        bytes32 msgHash = hashMessage(_message);
        if (messageStatus[msgHash] != Status.RETRIABLE) {
            revert B_NON_RETRIABLE();
        }

        // Attempt to invoke the messageCall.
        if (_invokeMessageCall(_message, msgHash, gasleft())) {
            _updateMessageStatus(msgHash, Status.DONE);
        } else if (_isLastAttempt) {
            _updateMessageStatus(msgHash, Status.FAILED);
        }
        emit MessageRetried(msgHash);
    }

    /// @notice Checks if the message was sent.
    /// @param _message The message.
    /// @return True if the message was sent.
    function isMessageSent(Message calldata _message) public view returns (bool) {
        if (_message.srcChainId != block.chainid) return false;
        return ISignalService(resolve("signal_service", false)).isSignalSent({
            _app: address(this),
            _signal: hashMessage(_message)
        });
    }

    /// @notice Checks if a msgHash has failed on its destination chain.
    /// @param _message The message.
    /// @param _proof The merkle inclusion proof.
    /// @return Returns true if the message has failed, false otherwise.
    function proveMessageFailed(
        Message calldata _message,
        bytes calldata _proof
    )
        public
        view
        returns (bool)
    {
        if (_message.srcChainId != block.chainid) return false;

        return _proveSignalReceived(
            resolve("signal_service", false),
            signalForFailedMessage(hashMessage(_message)),
            _message.destChainId,
            _proof
        );
    }

    /// @notice Checks if a msgHash has failed on its destination chain.
    /// @param _message The message.
    /// @param _proof The merkle inclusion proof.
    /// @return Returns true if the message has failed, false otherwise.
    function proveMessageReceived(
        Message calldata _message,
        bytes calldata _proof
    )
        public
        view
        returns (bool)
    {
        if (_message.destChainId != block.chainid) return false;
        return _proveSignalReceived(
            resolve("signal_service", false), hashMessage(_message), _message.srcChainId, _proof
        );
    }

    /// @notice Checks if the destination chain is enabled.
    /// @param _chainId The destination chain ID.
    /// @return enabled_ True if the destination chain is enabled.
    /// @return destBridge_ The bridge of the destination chain.
    function isDestChainEnabled(uint64 _chainId)
        public
        view
        returns (bool enabled_, address destBridge_)
    {
        destBridge_ = resolve(_chainId, "bridge", true);
        enabled_ = destBridge_ != address(0);
    }

    /// @notice Gets the current context.
    /// @inheritdoc IBridge
    function context() public view returns (Context memory ctx) {
        ctx = _loadContext();
        if (ctx.msgHash == 0 || ctx.msgHash == bytes32(PLACEHOLDER)) {
            revert B_INVALID_CONTEXT();
        }
    }

    /// @notice Returns invocation delay values.
    /// @dev Bridge contract deployed on L1 shall use a non-zero value for better
    /// security.
    /// @return invocationDelay_ The minimal delay in second before a message can be executed since
    /// and the time it was received on the this chain.
    /// @return invocationExtraDelay_ The extra delay in second (to be added to invocationDelay) if
    /// the transactor is not the preferredExecutor who proved this message.
    function getInvocationDelays()
        public
        view
        virtual
        returns (uint256 invocationDelay_, uint256 invocationExtraDelay_)
    {
        if (
            block.chainid == 1 // Ethereum mainnet
        ) {
            // For Taiko mainnet
            // 384 seconds = 6.4 minutes = one ethereum epoch
            return (1 hours, 384 seconds);
        } else if (
            block.chainid == 2 // Ropsten
                || block.chainid == 4 // Rinkeby
                || block.chainid == 5 // Goerli
                || block.chainid == 42 // Kovan
                || block.chainid == 17_000 // Holesky
                || block.chainid == 11_155_111 // Sepolia
        ) {
            // For all Taiko public testnets
            return (30 minutes, 384 seconds);
        } else if (block.chainid >= 32_300 && block.chainid <= 32_400) {
            // For all Taiko internal devnets
            return (5 minutes, 384 seconds);
        } else {
            // This is a Taiko L2 chain where no deleys are applied.
            return (0, 0);
        }
    }

    /// @notice Hash the message
    /// @param _message The message struct variable to be hashed.
    /// @return The hashed message.
    function hashMessage(Message memory _message) public pure returns (bytes32) {
        return keccak256(abi.encode("TAIKO_MESSAGE", _message));
    }

    /// @notice Returns a signal representing a failed/recalled message.
    /// @param _msgHash The message hash.
    /// @return The failed representation of it as bytes32.
    function signalForFailedMessage(bytes32 _msgHash) public pure returns (bytes32) {
        return _msgHash ^ bytes32(uint256(Status.FAILED));
    }

    /// @notice Checks if the given address can pause and unpause the bridge.
    function _authorizePause(address)
        internal
        view
        virtual
        override
        onlyFromOwnerOrNamed("bridge_pauser")
    { }

    /// @notice Invokes a call message on the Bridge.
    /// @param _message The call message to be invoked.
    /// @param _msgHash The hash of the message.
    /// @param _gasLimit The gas limit for the message call.
    /// @return success_ A boolean value indicating whether the message call was
    /// successful.
    /// @dev This function updates the context in the state before and after the
    /// message call.
    function _invokeMessageCall(
        Message calldata _message,
        bytes32 _msgHash,
        uint256 _gasLimit
    )
        private
        returns (bool success_)
    {
        if (_gasLimit == 0) revert B_INVALID_GAS_LIMIT();
        assert(_message.from != address(this));

        _storeContext({ _msgHash: _msgHash, _from: _message.from, _srcChainId: _message.srcChainId });

        if (
            _message.data.length >= 4 // msg can be empty
                && bytes4(_message.data) != IMessageInvocable.onMessageInvocation.selector
                && _message.to.isContract()
        ) {
            success_ = false;
        } else {
            (success_,) = ExcessivelySafeCall.excessivelySafeCall(
                _message.to,
                _gasLimit,
                _message.value,
                64, // return max 64 bytes
                _message.data
            );
        }

        // Reset the context after the message call
        _resetContext();
    }

    /// @notice Updates the status of a bridge message.
    /// @dev If the new status is different from the current status in the
    /// mapping, the status is updated and an event is emitted.
    /// @param _msgHash The hash of the message.
    /// @param _status The new status of the message.
    function _updateMessageStatus(bytes32 _msgHash, Status _status) private {
        if (messageStatus[_msgHash] == _status) return;

        messageStatus[_msgHash] = _status;
        emit MessageStatusChanged(_msgHash, _status);

        if (_status == Status.FAILED) {
            ISignalService(resolve("signal_service", false)).sendSignal(
                signalForFailedMessage(_msgHash)
            );
        }
    }

    /// @notice Resets the call context
    function _resetContext() private {
        if (block.chainid == 1) {
            _storeContext(bytes32(0), address(0), uint64(0));
        } else {
            _storeContext(bytes32(PLACEHOLDER), address(uint160(PLACEHOLDER)), uint64(PLACEHOLDER));
        }
    }

    /// @notice Stores the call context
    function _storeContext(bytes32 _msgHash, address _from, uint64 _srcChainId) private {
        if (block.chainid == 1) {
            assembly {
                tstore(_CTX_SLOT, _msgHash)
                tstore(add(_CTX_SLOT, 1), _from)
                tstore(add(_CTX_SLOT, 2), _srcChainId)
            }
        } else {
            _ctx = Context({ msgHash: _msgHash, from: _from, srcChainId: _srcChainId });
        }
    }

    /// @notice Loads the call context
    function _loadContext() private view returns (Context memory) {
        if (block.chainid == 1) {
            bytes32 msgHash;
            address from;
            uint64 srcChainId;
            assembly {
                msgHash := tload(_CTX_SLOT)
                from := tload(add(_CTX_SLOT, 1))
                srcChainId := tload(add(_CTX_SLOT, 2))
            }
            return Context({ msgHash: msgHash, from: from, srcChainId: srcChainId });
        } else {
            return _ctx;
        }
    }

    /// @notice Checks if the signal was received.
    /// @param _signalService The signalService
    /// @param _signal The signal.
    /// @param _chainId The ID of the chain the signal is stored on
    /// @param _proof The merkle inclusion proof.
    /// @return success_ True if the message was received.
    function _proveSignalReceived(
        address _signalService,
        bytes32 _signal,
        uint64 _chainId,
        bytes calldata _proof
    )
        private
        view
        returns (bool success_)
    {
        bytes memory data = abi.encodeCall(
            ISignalService.proveSignalReceived,
            (_chainId, resolve(_chainId, "bridge", false), _signal, _proof)
        );
        (success_,) = _signalService.staticcall(data);
    }
}
