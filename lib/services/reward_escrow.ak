use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address}
use cardano/assets.{PolicyId}
use ext/aiken/time.{PosixTime}

pub type RewardEscrowDatum {
  reward_issuer_nft: PolicyId,
  reward_issuer_address: Address,
  reward_receiver: VerificationKeyHash,
  escrow_expiration_timestamp: PosixTime,
}

pub type RewardEscrowRedeemer {
  ReceiveReward
  ReturnToIssuer
}
