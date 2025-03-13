use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use oracle/datum.{FeedVkh, NodeFeed, Nodes}

pub fn check_nodes_multisig(
  node_feeds: Pairs<FeedVkh, NodeFeed>,
  tx_signatories: List<VerificationKeyHash>,
  allowed_nodes: Nodes,
  required_node_signatures_count: Int,
) -> Bool {
  trace @"T6"

  let node_ids = pairs.keys(node_feeds)
  let nodes_count = list.length(node_ids)

  let allowed_nodes_dict = dict.from_ascending_pairs(allowed_nodes)
  let must_have_allowed_nodes =
    list.all(node_ids, dict.has_key(allowed_nodes_dict, _))

  // We don't need to check that node_ids list has unique keys, because list.difference removes only
  // the first occurrence of each element, while transaction signatories is a set (see cardano ledger spec)
  let must_have_all_feeds_uniquely_signed =
    list.difference(node_ids, tx_signatories) == []
  let must_pass_threshold = nodes_count >= required_node_signatures_count

  must_have_all_feeds_uniquely_signed && must_pass_threshold && must_have_allowed_nodes
}
