use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use oracle/datum.{FeedVkh, NodeFeed, Nodes}
use services/multisig.{Multisig, check_multisig}

pub fn check_nodes_multisig(
  node_feeds: Pairs<FeedVkh, NodeFeed>,
  tx_signatories: List<VerificationKeyHash>,
  nodes: Nodes,
  required_node_signatures_count: Int,
) -> Bool {
  let node_ids = pairs.keys(node_feeds)
  let must_have_unique_nodes =
    list.unique(node_ids)
      |> list.length
      |> fn(unique_count) { unique_count == list.length(node_ids) }

  let nodes_dict = dict.from_ascending_pairs(nodes)
  let must_have_allowed_nodes = list.all(node_ids, dict.has_key(nodes_dict, _))

  let multisig =
    Multisig {
      allowed_signatories: node_ids,
      required_signatories_count: required_node_signatures_count,
    }

  check_multisig(multisig, tx_signatories) && must_have_unique_nodes? && must_have_allowed_nodes?
}
