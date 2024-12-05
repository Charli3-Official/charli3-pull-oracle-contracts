use aiken/crypto.{VerificationKeyHash}
use aiken/option
use cardano/assets.{PolicyId}
use ext/aiken/math/rational.{Percent}
use ext/aiken/time.{PosixTime, PosixTimeDiff}
use ext/cardano/value.{Asset}

pub type OracleFeed =
  Int

pub type NodeFeed =
  Int

/// There are four types of oracle utxos:
/// 0. OracleSettings - one for each oracle,
///    acts as single point of truth for oracle settings and node list.
/// 1. RewardAccount - one for each oracle,
///    acts as single point of truth for reward distribution.
/// 2. RewardTransport - many for each oracle, with possibility of scaling their number on demand,
///    users perform ODV aggregation with those by providing node feeds list constructed off-chain.
/// 3. AggState - each AggState utxo is complementary to RewardTransport, it contains the oracle feed value,
///    that will be referenced by a user of a DApp.
pub type OracleDatum {
  OracleSettings(OracleSettingsDatum)
  RewardAccount(RewardAccountDatum)
  RewardTransport(RewardTransportDatum)
  AggState(Option<AggStateDatum>)
}

/// RewardTransport utxo can be in two states:
/// 1. NoRewards - waiting for user to submit tx with OdvAggregate redeemer;
/// 2. RewardConsensusPending - waiting to calculate aggregation reward distribution
///    and transfer user provided fees into RewardAccount utxo.
pub type RewardTransportDatum {
  NoRewards
  RewardConsensusPending(Aggregation)
}

pub type Aggregation {
  oracle_feed: OracleFeed,
  message: AggregateMessage,
  node_reward_price: Int,
  rewards_amount_paid: Int,
}

/// AggStateDatum contains an oracle feed - median taken from individual node feeds,
/// an expiration timestamp marking time after which AggState can be consumed once again,
/// and a created at timestamp for oracle users.
pub type AggStateDatum {
  oracle_feed: OracleFeed,
  expiry_timestamp: PosixTime,
  created_at: PosixTime,
}

/// Immutable oracle settings.
/// Rationale for immutability:
/// * platform_auth_nft - oracle deployment corresponds to one unchanging "platform"
/// * closing_period_length - oracle nodes will be sure that platform won't update this to a make very short interval
/// * reward_dismissing_period_length - oracle nodes will be sure that platform won't update this to a make very short interval
/// * fee_token - oracle nodes will be sure that platform won't update reward currency
pub type OracleConfiguration {
  /// platform is authorized by providing its input with specific NFT inside the transaction
  platform_auth_nft: PolicyId,
  /// closing period is when oracle can no longer do aggregations, but rewards can still be calculated
  closing_period_length: PosixTimeDiff,
  /// after this period rewards can be dismissed with DismissRewards redeemer
  reward_dismissing_period_length: PosixTimeDiff,
  /// oracle fees are paid using this asset, if it's None then ada is used
  fee_token: Option<Asset>,
}

pub type AggregateMessage {
  node_feeds_sorted_by_feed: Pairs<FeedVkh, NodeFeed>,
  node_feeds_count: Int,
  timestamp: PosixTime,
}

/// Mutable oracle settings
pub type OracleSettingsDatum {
  /// list of oracle nodes, node id is its FeedVkh
  nodes: Nodes,
  /// distinct node signatures number that passes multisig check
  required_node_signatures_count: Int,
  /// configuration of oracle fees
  fee_info: FeeConfig,
  /// aggregation is considered live, i.e. usable by dapps during this period
  aggregation_liveness_period: PosixTimeDiff,
  /// this is length of tx validity interval, so technically its value equals time absolute uncertainty times two,
  /// because we are taking tx validity interval middle as current time value
  time_absolute_uncertainty: PosixTimeDiff,
  /// see interquartile range (IQR) and Tukey fences methods for outlier detection,
  /// recommended value for this parameter is 150 (i.e. 1.5) or 170 in case of normal distribution
  iqr_fence_multiplier: Percent,
  /// this value equals zero when oracle fee token is any native asset (e.g. C3);
  /// in case oracle fee paid in ada it should be equal to a minimum ada amount held at maximum expected reward account utxo size,
  /// otherwise platform can withdraw more rewards than should be left for nodes
  utxo_size_safety_buffer: Int,
  /// if oracle is in closing state, then this field will have a certain timestamp value
  closing_period_started_at: Option<PosixTime>,
}

/// Reward distribution datum
pub type RewardAccountDatum {
  /// we get oracle node id (FeedVkh) mapped to node reward amount
  /// if we zip together Nodes keys (i.e. pairs first elements) and this list of reward amounts
  nodes_to_rewards: List<Int>,
}

// TODO consider removing PaymentVkh: that way operator uses FeedVkh to authorize collecting node rewards
// and pays tx fees from other address which is not known to the validator
/// An oracle node has two keys:
/// 1. FeedVkh - for verification of node feed inside the AggregateMessage.
///    Node operator does not store any kind of funds on this key, it's only for signing.
/// 2. PaymentVkh - exists only for node operator convenience:
///    so that he can pay tx fees and collect node rewards using one vkh.
/// WARNING nodes mapping should be sorted ascendingly by FeedVkh, to use it with aikens dict.from_ascending_pairs
pub type Nodes =
  Pairs<FeedVkh, PaymentVkh>

pub type FeedVkh =
  VerificationKeyHash

pub type PaymentVkh =
  VerificationKeyHash

pub type FeeConfig {
  rate_nft: Option<Asset>,
  reward_prices: RewardPrices,
}

pub type RewardPrices {
  node_fee: Int,
  platform_fee: Int,
}

pub fn is_oracle_closing(settings: OracleSettingsDatum) -> Bool {
  option.is_some(settings.closing_period_started_at)
}

pub fn has_no_rewards(reward_transport: RewardTransportDatum) -> Bool {
  when reward_transport is {
    NoRewards -> True
    RewardConsensusPending { .. } -> False
  }
}
