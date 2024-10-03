use aiken/collection/list
use aiken/option
use aiken/primitive/int
use oracle/datum.{NodeFeed, OracleFeed}

pub fn median(node_feeds: List<NodeFeed>) -> OracleFeed {
  let length = list.length(node_feeds)
  let sorted = list.sort(node_feeds, int.compare)

  if length % 2 == 0 {
    option.map2(
      list.at(sorted, length / 2),
      list.at(sorted, length / 2 - 1),
      fn(a, b) { ( a + b ) / 2 },
    )
  } else {
    list.at(sorted, length / 2)
  }
    |> option.or_else(fail @"median: empty list")
}
