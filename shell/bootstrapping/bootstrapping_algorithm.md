# Bootstrapping algorithm

## Overview

The general idea for the bootstrapping algorithm is as follows:
- query every peer's current branch
- attempt to find a short sequence (*segment*) of the blocks which is supported by a quorum of peers with which to extend the node's chain
  - first, get all the headers in this sequence
  - then, get the operations only for the blocks with a quorum of support
- continue extending by short segments until our current head has a timestamp within the threshold to be considered `Synced`

### Initial conditions

The node begins the bootstrapping process with:
- a current head (block), either genesis or a block provided by a snapshot
- a set of connections/peers
- an `Unsynced` synchronization status
- all peers with maximum `peer_score`
- all peers having the genesis block as their current head
- an `earliest_hashes` variable instantiated by an empty set
- a `pending_headers` variable instantiated by an empty map
- a `pending_operations` variable instantiated by an empty map

The `earliest_hashes` variable is used as a kind of temporary target to meet before applying blocks. This variable has a type like:

```rust
pub type Hashes = HashSet<BlockHashes>
```

The `pending_headers` and `pending_operations` variables are used to temporarily aggregate (the short segments mentioned above) headers and corresponding operations, respectively.

`pending_headers` has a type like:

```rust
pub type PendingHeaders = HashMap<BlockLevel, HashSet<HeaderData>>
```

where

```rust
pub struct HeaderData {
  header : Header,
  hash : BlockHash,
  supporters : HashSet<PeerId>
}
```

and `pending_operations` has a type like:

```rust
pub type PendingOperations = HashMap<Level, HashSet<Vec<Operation>>>
```

(these types are meant to be taken literally, just to give an idea)

### Steps

1. Request `Get_current_branch` from each peer (unless the peer has already advertised its current branch)
2. For each received `Current_branch` message:
  1. determine the *earliest* (lowest level) hash above the node's current head and add this hash to a global, mutable set `earliest_hashes`
  2. validate all hashes that correspond to a block with level at or below the node's current head's level
    - also check that none of these hashes is known to be invalid
    - disconnect from each peer which does not pass this validation step (their branch deviates from what the node takes as a given)
  3. adjust the peer's current head if the supplied header has a higher level or fitness
    - this is all the node does when handling `Current_head` messages while `Unsynced`
3. Request all headers corresponding to the hashes in `earliest_hashes` from each responsive peer by sending a `Get_block_headers` message
  - as the node receives more and more `Current_branch` messages, the collection of `earliest_hashes` grows
    - the node just uses whatever value it reads from `earliest_hashes` to make the list of headers it requests from each peer, initially
    - the node keeps track of which hashes have been requested from each peer and as we receive more earliest hashes, we make the corresponding block header requests from all peers whom we have not requested it
      - when new hashes are added to `earliest_hashes`, the node requests all these headers from the sender and the not-yet-requested ones from all other peers
    - ultimately, the node should request all received headers from each peer (well, not quite, see notes)
4. For each `Block_header` response:
  1. check hash of received header was actually requested from this peer
    - if the header wasn't requested, then should penalize the peer
  2. add header data to `pending_headers`
    - this requires calculating implied support for any known (i.e. pending) ancestors and support from children (see notes)
  3. check if any headers have a quorum of support
    - if not, the node continues requesting and handling block headers
    - else, prune the `pending_headers`
      - for each level, if there is a header with a quorum of support, remove the rest
      - any peer supporting a header other than the one with quorum support at any level should be penalized
  4. if it's not the case that all remaining headers in `pending_headers` have quorum support, then the node continues requesting and handling headers as before
    - effectively, the node goes back to step 3
    - else, continue to step 5
5. The node requests all operations for each block with a header in `pending_headers` from any peer it still has a connection with
  1. start with the operations for the earliest block and move to the latest, adding the operations to `pending_operations` upon receipt
  2. once the node has all operations for the earliest block, they apply it
  3. update current head accordingly
  4. repeat for all remaining pending blocks
6. After applying all blocks in the segment, clear the `earliest_hashes`, `pending_headers`, and `pending_operations` variables
  1. populate `earliest_hashes` with each of the peer's next earliest hash
  2. go back to requesting headers (step 3)

#### Notes on algorithm steps

1. These requests are made concurrently, order is irrelevant as long as the node makes a request to all peers
  - the node only needs to check if they already have a `Current_branch` message from the peer before sending a request
2. Each `Get_current_branch` message can be handled concurrently
  - the individual steps in 2. are performed sequentially for a given message/peer
  - whether `earliest_hashes` is implemented as a set or list without duplicates is irrelevant
  - the node uses the same technique for generating locators to determine the corresponding levels for the supplied hashes
    - the levels corresponding to the locator hashes can be generated from the node's and peer's ids and the level of the supplied head
  - obviously, we will need to have a locking mechanism for `earliest_hashes` since it will be read and written to by several threads
  - the node disregards the mempool portion of `Current_branch` messages while `Unsynced`
3. The order in which the node requests block headers from the responsive peers (those who have sent a `Current_branch` message) is not important as long as the node eventually sees a quorum of support for some of the requested block headers
  - these initial requests can be made concurrently
  - upon handling a `Current_branch` message, the node can immediately add the earliest hash from that peer to `earliest_hashes`
  - the later requests can also be made concurrently
    - it probably makes the most sense to have one worker per peer/connection which runs every so often, checks for new earliest hashes, and makes the corresponding requests
    - the frequency at which this worker performs these tasks should be proportional to the peer's score
  - we only need to request all earliest hashes from each peer if we don't have sufficient support for a single branch prior to this point
    - the goal here is to find a quorum of peers supporting one segment
      - the segment being from the block above the node's current head to the latest, earliest block
      - it is probably confusing to read a phase like "latest, earliest block"... all we mean here, is the latest (highest level) out of the earliest blocks
4. The node can handle `Block_header` messages concurrently
  - a penalty can either be a decrease to the peer's score or {grey, black}listing them
  - for example, if a peer `p` sends the node a header `hd`, they support this header explicitly
    - if the header of the predecessor is already in `pending_headers`, `p` also supports this header implicitly
    - similarly for other ancestors of `hd`
    - in the opposite direction, if `pending_headers` contains headers above `hd` which have `hd` as an ancestor, then all supporters of these headers must also support `hd`
  - headers can be requested strictly by `Get_block_headers` requests
    - once Octez supports `Get_predecessor_header` messages, these can speed up this process
5. The operation requests should be spread out among as many reliable peers as possible to parallelize the task
