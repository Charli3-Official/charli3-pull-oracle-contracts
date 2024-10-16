use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use oracle/datum.{Node, NodeFeed, NodeId}
use services/multisig.{Multisig, check_multisig}

pub fn check_nodes_multisig(
  node_feeds: Pairs<NodeId, NodeFeed>,
  tx_signatories: List<VerificationKeyHash>,
  nodes: List<Node>,
  required_node_signatures_count: Int,
) -> Bool {
  let node_ids = pairs.keys(node_feeds)
  let must_have_unique_nodes =
    list.unique(node_ids)
      |> list.length
      |> fn(unique_count) { unique_count == list.length(node_ids) }

  let node_feed_vkhs =
    list.indexed_map(nodes, fn(index, node) { (index, node.feed_vkh) })

  let multisig =
    Multisig {
      allowed_signatories: list.filter_map(
        node_feed_vkhs,
        fn((index, feed_vkh)) {
          if list.has(node_ids, index) {
            Some(feed_vkh)
          } else {
            None
          }
        },
      ),
      required_signatories_count: required_node_signatures_count,
    }

  check_multisig(multisig, tx_signatories) && must_have_unique_nodes?
}
