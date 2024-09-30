use aiken/crypto.{VerificationKeyHash}
use aiken/option
use cardano/assets.{PolicyId}
use ext/aiken/time.{PosixTime, PosixTimeDiff}
use ext/cardano/value.{Asset}

pub type OracleFeed =
  Int

/// There are three types of oracle utxos:
/// 1. RewardAccount - one for each oracle,
///    acts as single point of truth for oracle settings, node list, and reward distribution.
/// 2. RewardTransport - many for each oracle, with possibility of scaling their number on demand,
///    users permorm ODV aggregation with those by providing node feeds list constructed off-chain.
/// 3. AggState - each AggState utxo is complementary to RewardTransport, it containts the oracle feed value,
///    that will be referenced by a user of a DApp.
pub type OracleDatum {
  RewardAccount(RewardDatum)
  RewardTransport(RewardTransportDatum)
  AggState(Option<AggStateDatum>)
}

/// RewardTransport utxo can be in two states:
/// 1. NoRewards - waiting for user to submit tx with OdvAggregate redeemer;
/// 2. RewardConsensusPending - waiting to calculate aggregation reward distribution
///    and transfer user provided fees into RewardAccount utxo.
pub type RewardTransportDatum {
  NoRewards
  RewardConsensusPending { median: OracleFeed, message: AggregateMessage }
}

/// AggStateDatum contains an oracle feed - median taken from individual node feeds,
/// an expiration timestamp marking time after which AggState can be consumed once again,
/// and a created at timestamp for oracle users.
pub type AggStateDatum {
  median: OracleFeed,
  expiry_timestamp: PosixTime,
  created_at: PosixTime,
}

/// Immutable oracle settings.
/// Rationale for immutability:
/// * platform_auth_nft - oracle deployment corresponds to one unchanging "platform"
/// * closing_period_length - oracle nodes will be sure that platform won't update this to a make very short interval
/// * reward_dismissing_period_length - oracle nodes will be sure that platform won't update this to a make very short interval
/// * fee_token - oracle nodes will be sure that platform won't update reward currency
pub type OracleSettings {
  platform_auth_nft: PolicyId,
  closing_period_length: PosixTimeDiff,
  reward_dismissing_period_length: PosixTimeDiff,
  fee_token: Asset,
}

pub type AggregateMessage {
  node_feeds: List<NodeFeed>,
  timestamp: PosixTime,
}

pub type NodeFeed {
  value: Int,
  signature: ByteArray,
}

/// Mutable oracle settings and reward distribution data
pub type RewardDatum {
  nodes: List<Node>,
  fee_info: FeeConfig,
  aggregation_liveness_period: PosixTimeDiff,
  time_absolute_uncertainty: PosixTimeDiff,
  closing_period_started_at: Option<PosixTime>,
}

pub type Node {
  payment_vkh: VerificationKeyHash,
  feed_verification_key: ByteArray,
  reward: Int,
}

pub type FeeConfig {
  rate_nft: Option<Asset>,
  reward_prices: RewardPrices,
}

pub type RewardPrices {
  node_fee: Int,
  consensus_fee: Int,
  platform_fee: Int,
}

pub fn is_oracle_closing(reward_datum: RewardDatum) -> Bool {
  option.is_some(reward_datum.closing_period_started_at)
}

pub fn has_no_rewards(reward_transport: RewardTransportDatum) -> Bool {
  when reward_transport is {
    NoRewards -> True
    RewardConsensusPending { .. } -> False
  }
}
