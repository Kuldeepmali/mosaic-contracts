pragma solidity ^0.4.23;

// Copyright 2018 OpenST Ltd.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// ----------------------------------------------------------------------------
// Value Chain: Gateway Contract
//
// http://www.simpletoken.org/
//
// ----------------------------------------------------------------------------


import "./EIP20Interface.sol";
import "./MessageBus.sol";
import "./CoreInterface.sol";
import "./SimpleStake.sol";
import "./SafeMath.sol";
import "./Hasher.sol";
import "./ProofLib.sol";
import "./RLP.sol";

/**
 * @title Gateway Contract
 *
 *  @notice Gateway contract is staking Gateway that separates the concerns of staker and staking processor.
 *          Stake process is executed through Gateway contract rather than directly with the protocol contract.
 *          The Gateway contract will serve the role of staking account rather than an external account.
 *
 */
contract Gateway is Hasher {

	using SafeMath for uint256;

	/* Events */

	/** Emitted whenever a staking process is initiated. */
	event StakingIntentDeclared(
		bytes32 indexed _messageHash,
		address _staker,
		uint256 _stakerNonce,
		address _beneficiary,
		uint256 _amount
	);

	/** Emitted whenever a staking is completed. */
	event ProgressedStake(
		bytes32 indexed _messageHash,
		address _staker,
		uint256 _stakerNonce,
		uint256 _amount,
		bytes32 _unlockSecret
	);

	/** Emitted whenever a process is initiated to revert staking. */
	event RevertStakeIntentDeclared(
		bytes32 indexed _messageHash,
		address _staker,
		uint256 _stakerNonce,
		uint256 _amount
	);

	/** Emitted whenever a staking is reverted. */
	event RevertedStake(
		bytes32 indexed _messageHash,
		address _staker,
		uint256 _stakerNonce,
		uint256 _amount
	);

	/** Emitted whenever a redemption intent is confirmed. */
	event RedemptionIntentConfirmed(
		bytes32 indexed _messageHash,
		address _redeemer,
		uint256 _redeemerNonce,
		address _beneficiary,
		uint256 _amount,
		uint256 _blockHeight,
		bytes32 _hashLock
	);

	/** Emitted whenever a unstake process is complete. */
	event ProgressedUnstake(
		bytes32 indexed _messageHash,
		address _redeemer,
		uint256 _redeemerNonce,
		uint256 _amount,
		address _beneficiary,
		uint256 _reward
	);

	/** Emitted whenever a revert redemption intent is confirmed. */
	event RevertRedemptionIntentConfirmed(
		bytes32 indexed _messageHash,
		address _redeemer,
		uint256 _redeemerNonce,
		uint256 _amount
	);

	/** Emitted whenever a gateway and coGateway linking is initiated. */
	event GatewayLinkInitiated(
		bytes32 indexed _messageHash,
		address _gateway,
		address _cogateway,
		address _token
	);

	/** Emitted whenever a CoGateway contract is proven.
	 *	wasAlreadyProved parameter differentiates between first call and replay call of proveGateway method for same block height
	 */
	event CoGatewayProven(
		address _coGateway,
		uint256 _blockHeight,
		bytes32 _storageRoot,
		bool _wasAlreadyProved
	);

	/** Emitted whenever a gateway and coGateway linking is completed. */
	event GatewayLinkProgressed(
		bytes32 indexed _messageHash,
		address _gateway,
		address _cogateway,
		address _token,
		bytes32 _unlockSecret
	);

	/* Struct */

	/**
	 * Stake stores the staking information about the staking amount,
	 * beneficiary address, message data and facilitator address.
	 */
	struct Stake {

		/** Amount that will be staked. */
		uint256 amount;

		/**
		 * Address where the utility tokens will be minted in the
		 * auxiliary chain.
		 */
		address beneficiary;

		/** Message data. */
		MessageBus.Message message;

		/** Address of the facilitator that initiates the staking process. */
		address facilitator;
	}

	/**
	 * Unstake stores the unstaking / redeem information
	 * like unstake/redeem amount, beneficiary address, message data.
	 */
	struct Unstake {

		/** Amount that will be unstaked. */
		uint256 amount;

		/** Address that will receive the unstaked token */
		address beneficiary;

		/** Message data. */
		MessageBus.Message message;
	}

	/**
	 * GatewayLink stores data for linking of Gateway and CoGateway.
	 */
	struct GatewayLink {

		/**
		 * message hash is the sha3 of gateway address, cogateway address,
		 * bounty, token name, token symbol, token decimals , _nonce, token
		 */
		bytes32 messageHash;

		/** Message data. */
		MessageBus.Message message;
	}

	/* constants */

	uint8 constant OUTBOX_OFFSET = 1;

	/**
	 * Message box.
	 * @dev keep this is at location 1, in case this is changed then update
	 *      constant OUTBOX_OFFSET accordingly.
	 */
	MessageBus.MessageBox messageBox;

	/* public variables */

	/** CoGateway contract address. */
	address public coGateway;

	/** Specifies if the Gateway and CoGateway contracts are linked. */
	bool public linked;

	/** Specifies if the Gateway is deactivated for any new staking process. */
	bool public deactivated;

	/** Organisation address. */
	address public organisation;

	/** Escrow address to lock staked fund. */
	SimpleStake public stakeVault;

	/** amount of ERC20 which is staked by facilitator. */
	uint256 public bounty;

	/** address of ERC20 token. */
	EIP20Interface public token;

	/**
	 * address of ERC20 token in which
	 * the facilitator will stake for a process
	 */
	EIP20Interface public bountyToken;

	/** address of core contract. */
	CoreInterface public core;

	/** Maps messageHash to the Stake object. */
	mapping(bytes32 /*messageHash*/ => Stake) stakes;

	/** Maps messageHash to the Unstake object. */
	mapping(bytes32 /*messageHash*/ => Unstake) unstakes;

	/**
	 * Maps address to messageHash.
	 *
	 * Once the staking or unstaking process is started the corresponding
	 * message hash is stored against the staker/redeemer address. This is used
	 * to restrict simultaneous/multiple staking and unstaking for a particular
	 * address. This is also used to determine the nonce of the particular
	 * address. Refer getNonce for the details.
	 */
	mapping(address /*address*/ => bytes32 /*messageHash*/) activeProcess;

	/** Maps  blockHeigth to storageRoot*/
	mapping(uint256 /* block height */ => bytes32) private storageRoots;

	/* private variables */

	/** Gateway link. */
	GatewayLink gatewayLink;

	/** path to prove merkle account proof for CoGateway contract. */
	bytes private encodedCoGatewayPath;

	/* modifiers */

	/** checks that only organisation can call a particular function. */
	modifier onlyOrganisation() {
		require(
			msg.sender == organisation,
			"Only organisation can call the function"
		);
		_;
	}

	/** checks that contract is linked and is not deactivated */
	modifier isActive() {
		require(
			deactivated == false && linked == true,
			"Contract is restricted to use"
		);
		_;
	}

	/* Constructor */

	/**
	 * @notice Initialise the contract by providing the ERC20 token address
	 *         for which the gateway will enable facilitation of staking and
	 *         minting.
	 *
	 * @param _token The ERC20 token contract address that will be
	 *               staked and corresponding utility tokens will be minted
	 *               in auxiliary chain.
	 * @param _bountyToken The ERC20 token address that will be used for
	 *                     staking bounty from the facilitators.
	 * @param _core Core contract address.
	 * @param _bounty The amount that facilitator will stakes to initiate the
	 *                staking process.
	 * @param _organisation Organisation address.
	 */
	constructor(
		EIP20Interface _token, //TODO: think if this should this be ERC20TokenInterface
		EIP20Interface _bountyToken, //TODO: think of a better name
		CoreInterface _core,
		uint256 _bounty,
		address _organisation
	)
		public
	{
		require(
			_token != address(0),
			"Token contract address must not be zero"
		);
		require(
			_bountyToken != address(0),
			"Token contract address for bounty must not be zero"
		);
		require(
			_core != address(0),
			"Core contract address must not be zero"
		);
		require(
			_organisation != address(0),
			"Organisation address must not be zero"
		);

		// gateway and cogateway is not linked so it is initialized as false
		linked = false;

		// gateway is active
		deactivated = false;

		token = _token;
		bountyToken = _bountyToken;
		core = _core;
		bounty = _bounty;
		organisation = _organisation;

		// deploy simpleStake contract that will keep the staked amounts.
		stakeVault = new SimpleStake(token, address(this));
	}

	/* External functions */

	/**
 	 * @notice Initiate the Gateway and CoGateway contracts linking.
 	 *
 	 * @param _coGateway CoGateway contract address.
 	 * @param _intentHash Gateway and CoGateway linking intent hash.
 	 *                    This is a sha3 of gateway address, cogateway address,
	 *                    bounty, token name, token symbol, token decimals,
	 *                    _nonce, token.
 	 * @param _nonce Nonce of the sender. Here in this case its organisation
 	 *               address
 	 * @param _sender The address that signs the message hash. In this case it
 	 *                has to be organisation address
 	 * @param _hashLock Hash lock, set by the facilitator.
 	 * @param _signature Signed data.
 	 *
 	 * @return messageHash_ Message hash
 	 */
	function initiateGatewayLink(
		address _coGateway,
		bytes32 _intentHash,
		uint256 _nonce,
		address _sender,
		bytes32 _hashLock,
		bytes _signature
	)
		external
		returns (bytes32 messageHash_)
	{
		require(
			linked == false,
			"Gateway contract must not be linked"
		);
		require(
			deactivated == false,
			"Gateway contract must not be deactivated"
		);
		require(
			_coGateway != address(0),
			"CoGateway address must not be zero"
		);
		require(
			_sender == organisation,
			"Sender must be organisation address"
		);
		require(
			gatewayLink.messageHash == bytes32(0),
			"Linking is already initiated"
		);
		require(
			_nonce == _getNonce(_sender),
			"Sender nonce must be in sync"
		);

		// update the coGateway address
		coGateway = _coGateway;

		// update the encodedCoGatewayPath
		encodedCoGatewayPath = ProofLib.bytes32ToBytes(
			keccak256(abi.encodePacked(coGateway))
		);

		// TODO: need to add check for MessageBus. (This is already done in other branch)
		bytes32 intentHash = hashLinkGateway(
			address(this),
			coGateway,
			bounty,
			token.name(),
			token.symbol(),
			token.decimals(),
			_nonce,
			token);

		// Ensure that the _intentHash matches the calculated intentHash
		require(
			intentHash == _intentHash,
			"Incorrect intent hash"
		);

		// Get the message hash
		messageHash_ = MessageBus.messageDigest(
			GATEWAY_LINK_TYPEHASH,
			intentHash,
			_nonce,
			0
		);

		//TODO: Check when its deleted
		// update the gatewayLink storage
		gatewayLink = GatewayLink ({
		 	messageHash: messageHash_,
			message:getMessage(
                _sender,
                _nonce,
                0,
				0,
                _intentHash,
                _hashLock
            )
		});

		// Declare message in outbox
		MessageBus.declareMessage(
			messageBox,
			GATEWAY_LINK_TYPEHASH,
			gatewayLink.message,
			_signature
		);

		// emit GatewayLinkInitiated event
		emit GatewayLinkInitiated(
			messageHash_,
			address(this),
			coGateway,
			token
		);
	}

	/**
 	 * @notice Complete the Gateway and CoGateway contracts linking. This will
 	 *         set the variable linked to true, and thus it will activate the
 	 *         Gateway contract for stake and mint.
 	 *
 	 * @param _messageHash Message hash
 	 * @param _unlockSecret Unlock secret for the hashLock provide by the
 	 *                      facilitator while initiating the Gateway/CoGateway
 	 *                      linking
 	 *
 	 * @return `true` if gateway linking was successfully progressed
 	 */
	function progressGatewayLink(
		bytes32 _messageHash,
		bytes32 _unlockSecret
	)
		external
		returns (bool)
	{
		require(
			_messageHash != bytes32(0),
			"Message hash must not be zero"
		);
		require(
			_unlockSecret != bytes32(0),
			"Unlocl secret must not be zero"
		);
		require(
			gatewayLink.messageHash == _messageHash,
			"Unknown message type"
		);

		// Progress the outbox.
		MessageBus.progressOutbox(
			messageBox,
			GATEWAY_LINK_TYPEHASH,
			gatewayLink.message,
			_unlockSecret
		);

		// Update to specify the Gateway/CoGateway is linked
		linked = true;

		// Emit GatewayLinkProgressed event
		emit GatewayLinkProgressed(
			_messageHash,
			address(this),
			coGateway,
			token,
			_unlockSecret
		);

		return true;
	}

	/**
	 * @notice Initiates the stake process.
	 *
	 * @dev In order to stake the staker needs to approve Gateway contract for
	 *      stake amount. Staked amount is transferred from staker address to
	 *      Gateway contract.
	 *
	 * @param _amount Staking amount that will be transferred form staker
	 *                account.
	 * @param _beneficiary The address in the auxiliary chain where the utility
	 *                     tokens will be minted.
	 * @param _staker Staker address.
	 * @param _gasPrice Gas price that staker is ready to pay to get the stake
	 *                  and mint process done
	 * @param _gasLimit Gas limit that staker is ready to pay
	 * @param _nonce Nonce of the staker address.
	 * @param _hashLock Hash Lock provided by the facilitator.
	 * @param _signature Signature signed by staker.
	 *
	 * @return messageHash_ which is unique for each request.
	 */
	function stake(
		uint256 _amount,
		address _beneficiary,
		address _staker,
		uint256 _gasPrice,
		uint256 _gasLimit,
		uint256 _nonce,
		bytes32 _hashLock,
		bytes _signature
	)
		public
		isActive
		returns (bytes32 messageHash_)
	{
		require(
			_amount > uint256(0),
			"Stake amount must not be zero"
		);
		require(
			_beneficiary != address(0),
			"Beneficiary address must not be zero"
		);
		require(
			_staker != address(0),
			"Staker address must not be zero"
		);
		//TODO: Do we need this check ?
		require(
			_hashLock != bytes32(0),
			"HashLock must not be zero"
		);
		require(
			_signature.length == 65,
			"Signature must be of length 65"
		);

		//TODO: add _gasLimit in intent hash
		// Get the staking intent hash
		bytes32 intentHash = hashStakingIntent(
			_amount,
			_beneficiary,
			_staker,
			_gasPrice,
			token
		);

		// Get the messageHash
		messageHash_ = MessageBus.messageDigest(
			STAKE_TYPEHASH,
			intentHash,
			_nonce,
			_gasPrice
		);

		// Get previousMessageHash
		bytes32 previousMessageHash = initiateNewInboxProcess(
			_staker,
			_nonce,
			messageHash_
		);

		// Delete the progressed/Revoked stake data
		delete stakes[previousMessageHash];

		stakes[messageHash_] = Stake({
			amount : _amount,
			beneficiary : _beneficiary,
			facilitator : msg.sender,
			message : getMessage(
				_staker,
				_nonce,
				_gasPrice,
				_gasLimit,
				intentHash,
				_hashLock)
			});

		// Declare message in outbox
		MessageBus.declareMessage(
			messageBox,
			STAKE_TYPEHASH,
			stakes[messageHash_].message,
			_signature
		);

		//transfer staker amount to gateway
		require(token.transferFrom(_staker, address(this), _amount));

		// transfer the bounty amount // TODO: change the bounty transfer in BountyToken (Think for a name)
		require(bountyToken.transferFrom(msg.sender, address(this), bounty));

		// Emit StakingIntentDeclared event
		emit StakingIntentDeclared(
			messageHash_,
			_staker,
			_nonce,
			_beneficiary,
			_amount
		);
	}

	function progressStaking(
		bytes32 _messageHash,
		bytes32 _unlockSecret
	)
		external
		returns (
			address staker_,
			uint256 stakeAmount_
		)
	{
		require(_messageHash != bytes32(0));
		require(_unlockSecret != bytes32(0));
		MessageBus.Message storage message = stakes[_messageHash].message;

		staker_ = message.sender;
		stakeAmount_ = stakes[_messageHash].amount;

		MessageBus.progressOutbox(messageBox, STAKE_TYPEHASH, message, _unlockSecret);

		require(token.transfer(stakeVault, stakeAmount_));

		//return bounty
		require(bountyToken.transfer(msg.sender, bounty));

		emit ProgressedStake(
			_messageHash,
			staker_,
			message.nonce,
			stakeAmount_,
			_unlockSecret
		);
	}

	function progressStakingWithProof(
		bytes32 _messageHash,
		bytes _rlpEncodedParentNodes,
		uint256 _blockHeight,
		uint256 _messageStatus
	)
		external
		returns (uint256 stakeAmount_)
	{
		//require(linked);
		require(_messageHash != bytes32(0));
		require(_rlpEncodedParentNodes.length > 0);

		stakeAmount_ = stakes[_messageHash].amount;

		bytes32 storageRoot = storageRoots[_blockHeight];
		require(storageRoot != bytes32(0));

		MessageBus.Message storage message = stakes[_messageHash].message;

		//staker has started the revocation and facilitator has processed on utility chain
		//staker has to process with proof
		MessageBus.progressOutboxWithProof(
			messageBox,
			STAKE_TYPEHASH,
			message,
			_rlpEncodedParentNodes,
			OUTBOX_OFFSET,
			storageRoot,
			MessageBus.MessageStatus(_messageStatus)
		);

		require(token.transfer(stakeVault, stakeAmount_));

		//todo discuss return bounty
		require(bountyToken.transfer(stakes[_messageHash].facilitator, bounty));

		emit ProgressedStake(
			_messageHash,
			message.sender,
			message.nonce,
			stakes[_messageHash].amount,
			bytes32(0)
		);

	}

	function revertStaking(
		bytes32 _messageHash,
		bytes _signature
	)
		external
		returns (
			address staker_,
			uint256 stakerNonce_,
			uint256 amount_
		)
	{
		require(_messageHash != bytes32(0));

		MessageBus.Message storage message = stakes[_messageHash].message;

		require(message.intentHash != bytes32(0));

		require(
			MessageBus.declareRevocationMessage(
				messageBox,
				STAKE_TYPEHASH,
				message,
				_signature
			)
		);

		staker_ = message.sender;
		stakerNonce_ = message.nonce;
		amount_ = stakes[_messageHash].amount;

		emit RevertStakeIntentDeclared(
			_messageHash,
			staker_,
			stakerNonce_,
			amount_
		);

	}

	function progressRevertStaking(
		bytes32 _messageHash,
		uint256 _blockHeight,
		bytes _rlpEncodedParentNodes
	)
		external
		returns (bool /*TBD*/)
	{
		//require(linked);
		require(_messageHash != bytes32(0));
		require(_rlpEncodedParentNodes.length > 0);

		MessageBus.Message storage message = stakes[_messageHash].message;
		require(message.intentHash != bytes32(0));

		bytes32 storageRoot = storageRoots[_blockHeight];
		require(storageRoot != bytes32(0));

		require(
			MessageBus.progressRevocationMessage(
			messageBox,
			message,
			STAKE_TYPEHASH,
				OUTBOX_OFFSET,
			_rlpEncodedParentNodes,
				storageRoot
			)
		);

		Stake storage stakeData = stakes[_messageHash];

		require(token.transfer(message.sender, stakeData.amount));

		require(bountyToken.transfer(msg.sender, bounty));

		emit RevertedStake(
			_messageHash,
			message.sender,
			message.nonce,
			stakeData.amount
		);
	}

	function confirmRevertRedemptionIntent(
		bytes32 _messageHash,
		uint256 _blockHeight,
		bytes _rlpEncodedParentNodes
	)
		external
		returns (bool /*TBD*/)
	{
        uint256 initialGas = gasleft();
		//require(linked);
		require(_messageHash != bytes32(0));
		require(_rlpEncodedParentNodes.length > 0);

		MessageBus.Message storage message = unstakes[_messageHash].message;
		require(message.intentHash != bytes32(0));

		bytes32 storageRoot = storageRoots[_blockHeight];
		require(storageRoot != bytes32(0));

		require(MessageBus.confirmRevocation(
				messageBox,
				REDEEM_TYPEHASH,
				message,
				_rlpEncodedParentNodes,
				OUTBOX_OFFSET,
				storageRoot
			));

		emit RevertRedemptionIntentConfirmed(
			_messageHash,
			message.sender,
			message.nonce,
			unstakes[_messageHash].amount
		);

        message.gasConsumed = gasleft().sub(initialGas);
		return true;
	}

	function confirmRedemptionIntent(
		address _redeemer,
		uint256 _redeemerNonce,
		address _beneficiary,
		uint256 _amount,
		uint256 _gasPrice,
		uint256 _gasLimit,
		uint256 _blockHeight,
		bytes32 _hashLock,
		bytes memory _rlpParentNodes
	)
		public
		returns (bytes32 messageHash_)
	{
        uint256 initialGas = gasleft();
		require(_redeemer != address(0));
		require(_beneficiary != address(0));
		require(_amount != 0);
		require(_gasPrice != 0);
		require(_blockHeight != 0);
		require(_hashLock != bytes32(0));
		require(_rlpParentNodes.length != 0);

		//todo change to library call, stake too deep error
		bytes32 intentHash = hashRedemptionIntent(_amount, _beneficiary, _redeemer, _gasPrice, token);
		messageHash_ = MessageBus.messageDigest(REDEEM_TYPEHASH, intentHash, _redeemerNonce, _gasPrice);

		bytes32 previousMessageHash = initiateNewOutboxProcess(_redeemer, _redeemerNonce, messageHash_);
		delete unstakes[previousMessageHash];

		unstakes[messageHash_] = getUnStake(
			_amount,
			_beneficiary,
			_redeemer,
			_redeemerNonce,
			_gasPrice,
			_gasLimit,
			intentHash,
			_hashLock
		);

		executeConfirmRedemptionIntent(unstakes[messageHash_].message, _blockHeight, _rlpParentNodes);

		emit RedemptionIntentConfirmed(
			messageHash_,
			_redeemer,
			_redeemerNonce,
			_beneficiary,
			_amount,
			_blockHeight,
			_hashLock
		);

        unstakes[messageHash_].message.gasConsumed = gasleft().sub(initialGas);
	}

	function progressUnstake(
		bytes32 _messageHash,
		bytes32 _unlockSecret
	)
		external
		returns (
			uint256 unstakeTotalAmount_,
			uint256 unstakeAmount_,
			uint256 rewardAmount_
		)
	{
        uint256 initialGas = gasleft();
		//require(linked);
		require(_messageHash != bytes32(0));
		require(_unlockSecret != bytes32(0));

		MessageBus.Message storage message = unstakes[_messageHash].message;

        Unstake storage unStake = unstakes[_messageHash];
        MessageBus.progressInbox(messageBox, REDEEM_TYPEHASH, unStake.message, _unlockSecret);

		unstakeTotalAmount_ = unStake.amount;
		//TODO: Remove the hardcoded 50000. Discuss and implement it properly
		rewardAmount_ = MessageBus.feeAmount(message, initialGas, 50000); //21000 * 2 for transactions + approx buffer
		unstakeAmount_ = unStake.amount.sub(rewardAmount_);

		require(stakeVault.releaseTo(unStake.beneficiary, unstakeAmount_));
		//reward beneficiary with the reward amount
		require(token.transfer(msg.sender, rewardAmount_));

		emit ProgressedUnstake(
			_messageHash,
			message.sender,
			message.nonce,
			unstakeAmount_,
			unStake.beneficiary,
			rewardAmount_
		);
	}

	function progressUnstakeWithProof(
		bytes32 _messageHash,
		bytes _rlpEncodedParentNodes,
		uint256 _blockHeight,
		uint256 _messageStatus
	)
		public
		returns (
			uint256 unstakeTotalAmount_,
			uint256 unstakeAmount_,
			uint256 rewardAmount_
		)
	{
        uint256 initialGas = gasleft();
		//require(linked);
		require(_messageHash != bytes32(0));
		require(_rlpEncodedParentNodes.length > 0);

		MessageBus.Message storage message = unstakes[_messageHash].message;

		bytes32 storageRoot = storageRoots[_blockHeight];
		require(storageRoot != bytes32(0));

		Unstake storage unStake = unstakes[_messageHash];

        MessageBus.progressInboxWithProof(
            messageBox,
			REDEEM_TYPEHASH,
            unStake.message,
            _rlpEncodedParentNodes,
			OUTBOX_OFFSET,
            storageRoot,
            MessageBus.MessageStatus(_messageStatus)
        );

		unstakeTotalAmount_ = unStake.amount;
		//TODO: Remove the hardcoded 50000. Discuss and implement it properly
		rewardAmount_ = MessageBus.feeAmount(message, initialGas, 50000); //21000 * 2 for transactions + approx buffer
		unstakeAmount_ = unStake.amount.sub(rewardAmount_);

		require(stakeVault.releaseTo(unStake.beneficiary, unstakeAmount_));
		//reward beneficiary with the fee
		require(token.transfer(msg.sender, rewardAmount_));

		emit ProgressedUnstake(
			_messageHash,
			message.sender,
			message.nonce,
			unstakeAmount_,
			unStake.beneficiary,
			rewardAmount_
		);
	}


	/**
	 *  @notice External function prove gateway.
	 *
	 *  @dev proveGateway can be called by anyone to verify merkle proof of gateway contract address.
	 *		   Trust factor is brought by stateRoots mapping. stateRoot is committed in commitStateRoot function by mosaic process
	 *		   which is a trusted decentralized system running separately.
	 * 		   It's important to note that in replay calls of proveGateway bytes _rlpParentNodes variable is not validated. In this case
	 *		   input storage root derived from merkle proof account nodes is verified with stored storage root of given blockHeight.
	 *		   GatewayProven event has parameter wasAlreadyProved to differentiate between first call and replay calls.
	 *
	 *  @param _blockHeight Block height at which Gateway is to be proven.
	 *  @param _rlpEncodedAccount RLP encoded account node object.
	 *  @param _rlpParentNodes RLP encoded value of account proof parent nodes.
	 *
	 *  @return bool Status.
	 */
	function proveGateway(
		uint256 _blockHeight,
		bytes _rlpEncodedAccount,
		bytes _rlpParentNodes
	)
		external
		returns (bool /* success */)
	{
		// _rlpEncodedAccount should be valid
		require(_rlpEncodedAccount.length != 0, "Length of RLP encoded account is 0");
		// _rlpParentNodes should be valid
		require(_rlpParentNodes.length != 0, "Length of RLP parent nodes is 0");

		bytes32 stateRoot = core.getStateRoot(_blockHeight);
		// State root should be present for the block height
		require(stateRoot != bytes32(0), "State root is 0");

		// If account already proven for block height
		bytes32 provenStorageRoot = storageRoots[_blockHeight];

		if (provenStorageRoot != bytes32(0)) {
			// Check extracted storage root is matching with existing stored storage root
			require(provenStorageRoot == storageRoot, "Storage root mismatch when account is already proven");
			// wasAlreadyProved is true here since proveOpenST is replay call for same block height
			emit CoGatewayProven(
				coGateway,
				_blockHeight,
				storageRoot,
				true
			);
			// return true
			return true;
		}

		bytes32 storageRoot = ProofLib.proveAccount(_rlpEncodedAccount, _rlpParentNodes, encodedCoGatewayPath, stateRoot);

		storageRoots[_blockHeight] = storageRoot;
		// wasAlreadyProved is false since proveOpenST is called for the first time for a block height
		emit CoGatewayProven(
			coGateway,
			_blockHeight,
			storageRoot,
			false
		);

		return true;
	}

	/*private functions*/
	function executeConfirmRedemptionIntent(
		MessageBus.Message storage _message,
		uint256 _blockHeight,
		bytes _rlpParentNodes
	)
		private
	{
		bytes32 storageRoot = storageRoots[_blockHeight];
		require(storageRoot != bytes32(0));

		MessageBus.confirmMessage(
			messageBox,
			REDEEM_TYPEHASH,
			_message,
			_rlpParentNodes,
			OUTBOX_OFFSET,
			storageRoot);
	}

	function getUnStake(
		uint256 _amount,
		address _beneficiary,
		address _redeemer,
		uint256 _redeemerNonce,
		uint256 _gasPrice,
		uint256 _gasLimit,
		bytes32 _intentHash,
		bytes32 _hashLock
	)
		private
		pure
		returns (Unstake)
	{
		return Unstake({
			amount : _amount,
			beneficiary : _beneficiary,
			message : getMessage(_redeemer, _redeemerNonce, _gasPrice, _gasLimit, _intentHash, _hashLock)
			});
	}


	function getMessage(
		address _redeemer,
		uint256 _redeemerNonce,
		uint256 _gasPrice,
		uint256 _gasLimit,
		bytes32 _intentHash,
		bytes32 _hashLock
	)
		private
		pure
		returns (MessageBus.Message)
	{
		return MessageBus.Message({
			intentHash : _intentHash,
			nonce : _redeemerNonce,
			gasPrice : _gasPrice,
			gasLimit: _gasLimit,
			sender : _redeemer,
			hashLock : _hashLock,
            gasConsumed: 0
			});

	}

	function initiateNewOutboxProcess(
		address _account,
		uint256 _nonce,
		bytes32 _messageHash
	)
		private
		returns (bytes32 previousMessageHash_)
	{
		require(_nonce == _getNonce(_account));

		previousMessageHash_ = activeProcess[_account];

		if (previousMessageHash_ != bytes32(0)) {

			require(
				messageBox.outbox[previousMessageHash_] != MessageBus.MessageStatus.Progressed ||
				messageBox.outbox[previousMessageHash_] != MessageBus.MessageStatus.Revoked
			);
			//TODO: Commenting below line. Please check if deleting this will effect any process related to merkle proof in other chain.
			//delete messageBox.outbox[previousMessageHash_];
		}

		activeProcess[_account] = _messageHash;
	}

	function initiateNewInboxProcess(
		address _account,
		uint256 _nonce,
		bytes32 _messageHash
	)
		private
		returns (bytes32 previousMessageHash_)
	{
		require(_nonce == _getNonce(_account));

		previousMessageHash_ = activeProcess[_account];

		if (previousMessageHash_ != bytes32(0)) {

			require(
				messageBox.inbox[previousMessageHash_] != MessageBus.MessageStatus.Progressed ||
				messageBox.inbox[previousMessageHash_] != MessageBus.MessageStatus.Revoked
			);
			//TODO: Commenting below line. Please check if deleting this will effect any process related to merkle proof in other chain.
			//delete messageBox.inbox[previousMessageHash_];
		}

		activeProcess[_account] = _messageHash;
	}

	function _getNonce(address _account)
		private
		view
		returns (uint256 /* nonce */)
	{
		bytes32 messageHash = activeProcess[_account];
		if (messageHash == bytes32(0)) {
			return 0;
		}

		MessageBus.Message storage message = stakes[messageHash].message;
		return message.nonce.add(1);
	}

	function getNonce(address _account)
		external
		view
		returns (uint256 /* nonce */)
	{
		return _getNonce(_account);
	}

	function isLinked()
		external
		view
		returns (bool)
	{
		return linked;
	}

	function isDeactivated()
		external
		view
		returns (bool)
	{
		return deactivated;
	}

	function setGatewayActive(bool _active)
		external
		onlyOrganisation
		returns (bool)
	{
		deactivated = !_active;
	}
}




