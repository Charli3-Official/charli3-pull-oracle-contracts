use aiken/builtin
use aiken/collection/list
use aiken/collection/pairs
use aiken/math/rational
use ext/aiken/math/rational.{Percent, per_cent} as ext
use oracle/datum.{NodeFeed, NodeId, OracleFeed}
use services/iqr.{iqr_fence, quantile}

// TODO fail if node_feeds_count < 4 in mainnet
pub fn median(
  node_feeds_sorted: List<NodeFeed>,
  node_feeds_count: Int,
) -> OracleFeed {
  when node_feeds_sorted is {
    [] -> fail @"median: empty list"
    [x] -> x
    xs -> {
      expect Some(midpoint) = rational.new(1, 2)
      quantile(xs, node_feeds_count, midpoint) |> rational.round_even
    }
  }
}

/// Returns list of nodes which are not outliers using interquartile range algorithm (IQR).
pub fn consensus_by_iqr(
  node_feeds: Pairs<NodeId, NodeFeed>,
  node_feeds_count: Int,
  iqr_fence_multiplier: Percent,
) -> List<NodeId> {
  if node_feeds_count < 4 {
    pairs.keys(node_feeds)
  } else {
    expect Some(multiplier) = rational.new(iqr_fence_multiplier, per_cent)
    let (lower_fence, upper_fence) =
      pairs.values(node_feeds)
        |> iqr_fence(node_feeds_count, multiplier)
    let lower_limit = rational.round_even(lower_fence)
    let upper_limit = rational.round_even(upper_fence)

    list.filter_map(
      node_feeds,
      fn(p) {
        let id = builtin.fst_pair(p)
        let feed = builtin.snd_pair(p)

        if feed < lower_limit || feed > upper_limit {
          None
        } else {
          Some(id)
        }
      },
    )
  }
}
