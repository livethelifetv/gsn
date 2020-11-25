// SPDX-License-Identifier:MIT
pragma solidity ^0.6.2;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/cryptography/ECDSA.sol";

import "./utils/RLPReader.sol";
import "./utils/GsnUtils.sol";
import "./interfaces/IRelayHub.sol";
import "./interfaces/IPenalizer.sol";

contract Penalizer is IPenalizer {

    string public override versionPenalizer = "2.1.0+opengsn.penalizer.ipenalizer";

    using ECDSA for bytes32;

    uint constant public PENALIZE_BLOCK_DELAY = 5;

    function decodeTransaction(bytes memory rawTransaction) private pure returns (Transaction memory transaction) {
        (transaction.nonce,
        transaction.gasPrice,
        transaction.gasLimit,
        transaction.to,
        transaction.value,
        transaction.data) = RLPReader.decodeTransaction(rawTransaction);
        return transaction;
    }

    mapping(bytes32 => uint) public commits;

    event Commit(bytes32 indexed commitHash, address sender);

    /**
     * any sender can call "commit(keccak(encodedPenalizeFunction))", to make sure
     * no-one can front-run it to claim this penalization
     */
    function commit(bytes32 msgDataHash, uint revealSalt) external override {
        bytes32 idx = keccak256(abi.encodePacked(msgDataHash, revealSalt, msg.sender));
        commits[idx] = block.number;
        emit Commit(msgDataHash, msg.sender);
    }

    modifier relayManagerOnly(IRelayHub hub) {
        require(hub.isRelayManagerStaked(msg.sender), "Unknown relay manager");
        _;
    }

    modifier commitRevealOnly(uint revealSalt) {
        bytes32 msgDataHash = keccak256(msg.data);
        bytes32 idx = keccak256(abi.encodePacked(msgDataHash, revealSalt, msg.sender));
        uint commitValue = commits[idx];
        require(commitValue != 0, "no commit");
        require(commitValue + PENALIZE_BLOCK_DELAY < block.number, "must wait before revealing penalize");
        _;
    }

    function penalizeRepeatedNonce(
        bytes memory unsignedTx1,
        bytes memory signature1,
        bytes memory unsignedTx2,
        bytes memory signature2,
        IRelayHub hub
    )
    public
    override
    relayManagerOnly(hub)
    {
        _penalizeRepeatedNonce(unsignedTx1, signature1, unsignedTx2, signature2, hub);
    }

    function penalizeRepeatedNonceWithSalt(
        bytes memory unsignedTx1,
        bytes memory signature1,
        bytes memory unsignedTx2,
        bytes memory signature2,
        IRelayHub hub,
        uint revealSalt
    )
    public
    override
    commitRevealOnly(revealSalt) {
        _penalizeRepeatedNonce(unsignedTx1, signature1, unsignedTx2, signature2, hub);
    }

    function _penalizeRepeatedNonce(
        bytes memory unsignedTx1,
        bytes memory signature1,
        bytes memory unsignedTx2,
        bytes memory signature2,
        IRelayHub hub
    )
    private
    {
        // Can be called by a relay manager only.
        // If a relay attacked the system by signing multiple transactions with the same nonce
        // (so only one is accepted), anyone can grab both transactions from the blockchain and submit them here.
        // Check whether unsignedTx1 != unsignedTx2, that both are signed by the same address,
        // and that unsignedTx1.nonce == unsignedTx2.nonce.
        // If all conditions are met, relay is considered an "offending relay".
        // The offending relay will be unregistered immediately, its stake will be forfeited and given
        // to the address who reported it (msg.sender), thus incentivizing anyone to report offending relays.
        // If reported via a relay, the forfeited stake is split between
        // msg.sender (the relay used for reporting) and the address that reported it.

        address addr1 = keccak256(abi.encodePacked(unsignedTx1)).recover(signature1);
        address addr2 = keccak256(abi.encodePacked(unsignedTx2)).recover(signature2);

        require(addr1 == addr2, "Different signer");
        require(addr1 != address(0), "ecrecover failed");

        Transaction memory decodedTx1 = decodeTransaction(unsignedTx1);
        Transaction memory decodedTx2 = decodeTransaction(unsignedTx2);

        // checking that the same nonce is used in both transaction, with both signed by the same address
        // and the actual data is different
        // note: we compare the hash of the tx to save gas over iterating both byte arrays
        require(decodedTx1.nonce == decodedTx2.nonce, "Different nonce");

        bytes memory dataToCheck1 =
        abi.encodePacked(decodedTx1.data, decodedTx1.gasLimit, decodedTx1.to, decodedTx1.value);

        bytes memory dataToCheck2 =
        abi.encodePacked(decodedTx2.data, decodedTx2.gasLimit, decodedTx2.to, decodedTx2.value);

        require(keccak256(dataToCheck1) != keccak256(dataToCheck2), "tx is equal");

        penalize(addr1, hub);
    }

    function penalizeIllegalTransaction(
        bytes memory unsignedTx,
        bytes memory signature,
        IRelayHub hub
    )
    public
    override
    relayManagerOnly(hub)
    {
        _penalizeIllegalTransaction(unsignedTx, signature, hub);
    }

    function penalizeIllegalTransactionWithSalt(
        bytes memory unsignedTx,
        bytes memory signature,
        IRelayHub hub,
        uint revealSalt
    )
    public
    override
    commitRevealOnly(revealSalt) {
        _penalizeIllegalTransaction(unsignedTx, signature, hub);
    }

    function _penalizeIllegalTransaction(
        bytes memory unsignedTx,
        bytes memory signature,
        IRelayHub hub
    )
    private
    {
        Transaction memory decodedTx = decodeTransaction(unsignedTx);
        if (decodedTx.to == address(hub)) {
            bytes4 selector = GsnUtils.getMethodSig(decodedTx.data);
            bool isWrongMethodCall = selector != IRelayHub.relayCall.selector;
            bool isGasLimitWrong = GsnUtils.getParam(decodedTx.data, 4) != decodedTx.gasLimit;
            require(
                isWrongMethodCall || isGasLimitWrong,
                "Legal relay transaction");
        }
        address relay = keccak256(abi.encodePacked(unsignedTx)).recover(signature);
        require(relay != address(0), "ecrecover failed");

        penalize(relay, hub);
    }

    function penalize(address relayWorker, IRelayHub hub) private {
        hub.penalize(relayWorker, msg.sender);
    }
}
