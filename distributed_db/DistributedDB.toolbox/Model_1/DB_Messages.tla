---------------------------- MODULE DB_Messages -----------------------------

CONSTANTS numChains, numNodes, sizeBound

VARIABLES network_info, node_info

LOCAL INSTANCE DB_Defs
LOCAL INSTANCE Utils

-----------------------------------------------------------------------------

\* There 3 types of messages:
\* - Full (advertise/request)
\* - Synchronization (expect/acknowledge/error)
\* - System

-----------------------------------------------------------------------------

(***************************************)
(* Full messages (2 kinds):            *)
(* - Advertise messages                *)
(* - Request messages                  *)
(***************************************)

(* Advertise messages *)
(* Used to respond to specific requests and to broadcast messages to all active nodes on a chain *)

\* - Current_branch
\* - Current_head
\* - Block_header
\* - Operations

\* Advertise message parameters
AdParams ==
    [ branch : Branches ] \* Current_branch
    \cup
    [ branch : Branches, height : Heights ] \* Current_head
    \cup
    [ branch : Branches, height : Heights, header : Headers ] \* Block_header
    \cup
    [ branch : Branches, height : Heights, ops : Operations ] \* Operations

\* Advertise message types
AdMsgTypes == { "Current_branch", "Current_head", "Block_header", "Operations" }

\* Advertise messages
AdMsgs == [ from : Nodes, type : AdMsgTypes, params : AdParams ]


(* Request messages *)
(* Used to request specific info either from a single node or from all active nodes on a chain *)

\* - Get_current_branch
\* - Get_current_head
\* - Get_block_header
\* - Get_operations

\* Request message parameters
ReqParams ==
    [ chain : Chains ] \* Get_current_branch
    \cup
    [ branch : Branches ] \* Get_current_head
    \cup
    [ branch : Branches, height : Heights ] \* Get_block_header & Get_operations

\* Request message types
ReqMsgTypes == { "Get_current_branch", "Get_current_head", "Get_block_header", "Get_operations" }

\* Request messages
ReqMsgs == [ from : Nodes, type : ReqMsgTypes, params : ReqParams ]

\* A full message is either an advertise or request message
FullMsgs == AdMsgs \cup ReqMsgs

-----------------------------------------------------------------------------

(***************************************)
(* Synchronization messages (2 kinds): *)
(* - Expect messages                   *)
(* - Acknowledgment/error messages     *)
(***************************************)

(* Acknowledgment messages *)
(* Used to acknowlegde the receipt of a message from a node *)

\* Error message params
ErrorMsgParams == [ branch : Branches, height : Heights ]

\* Error message types
ErrorMsgTypes == { "Err_block_header", "Err_operations" }

\* Error messages
ErrorMsgs == [ from : Nodes, type : ErrorMsgTypes, error : ErrorMsgParams ]

\* Acknowledgment message types
AckMsgTypes == { "Ack_current_branch", "Ack_current_head", "Ack_block_header", "Ack_operations" }

\* Acknowledgment/error messages
AckMsgs == [ from : Nodes, type : AckMsgTypes ]

(* Expect messages *)
(* Used to register an expected response from a node *)

\* Expect message parameters
ExpectParams == ReqParams

\* Expect message types
ExpectMsgTypes == AdMsgTypes \cup AckMsgTypes \cup ErrorMsgTypes

\* Expect messages
ExpectMsgs == [ from : Nodes, type : ExpectMsgTypes, expect : ExpectParams ]

\* A sync message is either an ack or expect message
SyncMsgs == AckMsgs \cup ExpectMsgs \cup ErrorMsgs

-----------------------------------------------------------------------------

(*******************)
(* System messages *)
(*******************)

NewBlock == { "New_block" }

NewBranch == { "New_branch" }

NewChain == { "New_chain" }

\* System message types
SysMsgTypes == NewBlock \cup NewBranch \cup NewChain

\* System message parameters
SysParams ==
    [ block : Blocks ] \* New_block
    \cup
    [ branch : Branches ] \* New_branch
    \cup
    [ chain : Chains ] \* New_chain

\* System messages
SysMsgs == [ type : SysMsgTypes, params : SysParams ]

-----------------------------------------------------------------------------

(****************)
(* All messages *)
(****************)

Messages == FullMsgs \cup ExpectMsgs \cup SysMsgs

-----------------------------------------------------------------------------

\* full message predicate
isFullMsg[ msg \in Messages ] == DOMAIN msg = { "from", "params", "type" }

\* ack message predicate
isAckMsg[ msg \in Messages ] == DOMAIN msg = { "from", "type" }

\* error message predicate
isErrorMsg[ msg \in Messages ] == DOMAIN msg = { "error", "from", "type" }

\* expect message predicate
isExpectMsg[ msg \in Messages ] == DOMAIN msg = { "expect", "from", "type" }

\* system message predicate
isSysMsg[ msg \in Messages ] == DOMAIN msg = { "params", "type" }

\* Message "constructors"
\* validates [type] matches [params] and creates the message
\* invalid type/param pairs will return a TLC error

OnlyChain == { "Get_current_branch" }

OnlyBranch == { "Get_current_head", "Current_branch" }

BranchHeight == { "Get_block_header", "Get_operations", "Current_head" }

BranchHeightOps == { "Operations" }

BranchHeightHeader == { "Block_header" }

\* Full message "constructor"
Msg(from, type, params) ==
    CASE \/ /\ type \in OnlyChain
            /\ DOMAIN params = { "chain" }
         \/ /\ type \in OnlyBranch
            /\ DOMAIN params = { "branch" }
         \/ /\ type \in BranchHeight
            /\ DOMAIN params = { "branch", "height" }
         \/ /\ type \in BranchHeightOps
            /\ DOMAIN params = { "branch", "height", "ops" }
         \/ /\ type \in BranchHeightHeader
            /\ DOMAIN params = { "branch", "height", "header" } ->
         [ from |-> from, type |-> type, params |-> params ]

\* Synchronization message "constructors"
ExpectMsg(from, type, expect) ==
    CASE type \in ExpectMsgTypes -> [ from |-> from, type |-> type, expect |-> expect ]

AckMsg(from, type) ==
    CASE type \in AckMsgTypes -> [ from |-> from, type |-> type ]

ErrorMsg(from, type, error) ==
    CASE type \in ErrorMsgTypes -> [ from |-> from, type |-> type, error |-> error ]

\* System message "constructor"
SysMsg(type, params) ==
    CASE \/ /\ type \in NewBlock
            /\ DOMAIN params = { "block" }
         \/ /\ type \in NewBranch
            /\ DOMAIN params = { "branch" }
         \/ /\ type \in NewChain
            /\ DOMAIN params = { "chain" } -> [ type |-> type, params |-> params ]

-----------------------------------------------------------------------------

(****************)
(* Expectations *)
(****************)

\* compute set of expected responses for [msg]
\* this set is either empty or contains a single expect message
expect_msg[ to \in Nodes, msg \in FullMsgs ] ==
    LET type   == msg.type
        params == msg.params
    IN
      CASE \* Request messages - advertise expected
           type = "Get_current_branch" -> {ExpectMsg(to, "Current_branch", [ chain |-> params.chain ])}
        [] type = "Get_current_head" ->
           {ExpectMsg(to, "Current_head", [ chain |-> params.chain, branch |-> params.branch ])}
        [] type = "Get_block_header" ->
           {ExpectMsg(to, "Block_header",
             [ chain |-> params.chain, branch |-> params.branch, height |-> params.height ])}
        [] type = "Get_operations" ->
           {ExpectMsg(to, "Operation",
             [ chain |-> params.chain, branch |-> params.branch, height |-> params.height, ops |-> params.ops ])}
           \* Advertise messages - ack expected
        [] type = "Current_branch" -> {AckMsg(to, "Ack_current_branch")}
        [] type = "Current_head"   -> {AckMsg(to, "Ack_current_head")}
        [] type = "Block_header"   -> {AckMsg(to, "Ack_block_header")}
        [] type = "Operations"     -> {AckMsg(to, "Ack_operations")}
           \* Acknowledgment messages
        [] type \in AckMsgTypes -> {} \* no response expected from an acknowledgement

type_of_expect[ type \in ExpectMsgTypes ] ==
      \* advertise messages are expected as responses to request messages
    CASE type = "Current_branch" -> "Get_current_branch"
      [] type = "Current_head" -> "Get_current_head"
      [] type = "Block_header" -> "Get_block_header"
      [] type = "Operations" -> "Get_operations"
      \* acknowledgments are expected as responses to advertise messages
      [] type = "Ack_current_branch" -> "Current_branch"
      [] type = "Ack_current_head" -> "Current_head"
      [] type = "Ack_block_header" -> "Block_header"
      [] type = "Ack_operations" -> "Operations"

msg_of_expect[ node \in Nodes, chain \in Chains, exp \in ExpectMsgs ] ==
    LET from   == exp.from
        params == exp.expect
        type   == exp.type
    IN Msg(from, type_of_expect[type], params)

-----------------------------------------------------------------------------

(*************************)
(* Message-based actions *)
(*************************)

\* [node] receives a message on [chain]
\* [node] must have space to receive a message on [chain]
Recv(node, chain, msg) ==
    node_info' = [ node_info EXCEPT !.messages[node][chain] = checkAppend(@, msg) ]

\* [node] consumes a sent message on [chain]
\* [node] must have messages on [chain] to consume
Consume_sent(chain, node, msg) ==
    network_info' = [ network_info EXCEPT !.sent[chain][node] = @ \ {msg} ]

\* [node] consumes and handles a received message on [chain] and consumes corresponding expectation
\* [node] must have received messages on [chain]
Consume_msg(node, chain, msg) ==
    node_info' = [ node_info EXCEPT !.messages[node][chain] = Tail(@),
                                    !.expect[node][chain] = @ \ expect_msg[node, msg] ]

\* Send [msg] to [to] on [chain]
Send(to, chain, msg) ==
    network_info' = [ network_info EXCEPT !.sent[chain][to] = checkAdd(@, msg) ]

\* Register an expectation
Expect(from, to, chain, msg) ==
    node_info' = [ node_info EXCEPT !.expect[from][chain] = checkUnion(@, expect_msg[to, msg]) ]

\* Sends [msg] to all active nodes on [chain] who can recieve it
BroadcastToActive(from, chain, msg) ==
    network_info' = [ network_info EXCEPT !.sent[chain] = checkAddToActive(from, chain, msg) ]

=============================================================================