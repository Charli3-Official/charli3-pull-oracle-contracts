use aiken/collection/pairs
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/option
use cardano/assets.{PolicyId}
use ext/aiken/math/rational.{Percent}
use ext/aiken/time.{PosixTime, PosixTimeDiff}
use ext/cardano/value.{Asset}

pub type OracleFeed =
  Int

pub type NodeFeed =
  Int

/// A mapping structure that stores key-value pairs.
/// It is used to store price-related data in the PriceData structure.
pub type PriceMap =
  Pairs<Int, Int>

/// The main data structure representing price-related information.
/// It can contain shared, extended, or generic data.
pub type PriceData {
  SharedData
  ExtendedData
  GenericData { price_map: PriceMap }
}

/// Retrieves a price-related value from the PriceData structure using an index.
pub fn get_price_data(price_data: PriceData, index: Int) -> Option<Int> {
  expect GenericData(price_map) = price_data
  pairs.get_first(price_map, index)
}

/// Creates a PriceData object with price, creation time, and expiration time.
pub fn create_price_data(
  price: Int,
  time_creation: Int,
  time_expiration,
) -> PriceData {
  GenericData(
    [Pair(0, price), Pair(1, time_creation), Pair(2, time_expiration)],
  )
}

/// There are four types of oracle utxos:
/// 0. AggState - each AggState utxo is complementary to RewardTransport, it contains the oracle feed value,
///    that will be referenced by a user of a DApp.
/// 1. OracleSettings - one for each oracle,
///    acts as single point of truth for oracle settings and node list.
/// 2. RewardAccount - one for each oracle,
///    acts as single point of truth for reward distribution.
/// 3. RewardTransport - many for each oracle, with possibility of scaling their number on demand,
///    users perform ODV aggregation with those by providing node feeds list constructed off-chain.
pub type OracleDatum {
  AggState(PriceData)
  OracleSettings(OracleSettingsDatum)
  RewardAccount(RewardAccountDatum)
  RewardTransport(RewardTransportDatum)
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

/// Immutable oracle settings.
/// Rationale for immutability:
/// * platform_auth_nft - oracle deployment corresponds to one unchanging "platform"
/// * pause_period_length - oracle nodes will be sure that platform won't update this to a make very short interval
/// * reward_dismissing_period_length - oracle nodes will be sure that platform won't update this to a make very short interval
/// * fee_token - oracle nodes will be sure that platform won't update reward currency
/// * reward_escrow_script_hash - oracle nodes will be sure that the reward escrow script is fair
pub type OracleConfiguration {
  /// platform is authorized by providing its input with specific NFT inside the transaction
  platform_auth_nft: PolicyId,
  /// pause period is when oracle can no longer do aggregations, but rewards can still be calculated
  pause_period_length: PosixTimeDiff,
  /// after this period rewards can be dismissed with DismissRewards redeemer
  reward_dismissing_period_length: PosixTimeDiff,
  /// oracle fees are paid using this asset, if it's None then ada is used
  fee_token: Option<Asset>,
  /// when oracle platform removes nodes it will do a final token reward payout to this address,
  /// ada rewards are paid to nodes PaymentVkh, so escrow script hash can be set to ""
  reward_escrow_script_hash: ScriptHash,
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
  /// max tx validity interval length for odv-aggregation tx
  time_uncertainty_aggregation: PosixTimeDiff,
  /// max tx validity interval length for platform governance txs
  time_uncertainty_platform: PosixTimeDiff,
  /// see interquartile range (IQR) and Tukey fences methods for outlier detection,
  /// recommended value for this parameter is 150 (i.e. 1.5) or 170 in case of normal distribution
  iqr_fence_multiplier: Percent,
  /// this value is always larger than zero,
  /// should be equal to a minimum ada amount held at maximum expected oracle utxo size
  utxo_size_safety_buffer: Int,
  /// if oracle is in pause state, then this field will have a certain timestamp value
  pause_period_started_at: Option<PosixTime>,
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

pub fn is_oracle_paused(settings: OracleSettingsDatum) -> Bool {
  option.is_some(settings.pause_period_started_at)
}

pub fn has_no_rewards(reward_transport: RewardTransportDatum) -> Bool {
  when reward_transport is {
    NoRewards -> True
    RewardConsensusPending { .. } -> False
  }
}
