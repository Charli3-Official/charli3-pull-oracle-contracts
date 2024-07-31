use aiken/time.{PosixTime}
use aiken/transaction/value.{PolicyId}

/// NodeMessage is serialized hashed and signed by node operator,
/// it contains the feed value, together with security parameters:
/// * timestamp - user is guarantied that value is at least as fresh as this time,
///               and node is sure that his signature will expire soon after this time passes.
/// * oracle_nft_policy_id - acts as feed ID, therefore ensures that node message won't be reused for other feeds
pub type NodeMessage {
  value: Int,
  timestamp: PosixTime,
  oracle_nft_policy_id: PolicyId,
}
