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
  let must_have_unique_nodes =
    list.unique(node_ids)
      |> list.length
      |> fn(unique_count) { unique_count == nodes_count }

  let allowed_nodes_dict = dict.from_ascending_pairs(allowed_nodes)
  let must_have_allowed_nodes =
    list.all(node_ids, dict.has_key(allowed_nodes_dict, _))

  let must_have_all_feeds_signed =
    list.difference(node_ids, tx_signatories) == []
  let must_pass_threshold = nodes_count >= required_node_signatures_count

  must_have_all_feeds_signed && must_pass_threshold && must_have_unique_nodes && must_have_allowed_nodes
}
