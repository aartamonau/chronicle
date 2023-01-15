%% @author Couchbase <info@couchbase.com>
%% @copyright 2020 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(chronicle_leader).

-include("chronicle.hrl").

-behavior(gen_statem).

-export([start_link/0]).
-export([get_leader/0,
         wait_for_leader/0, wait_for_leader/1, wait_for_leader/2,
         announce_leader_status/0,
         note_term_finished/2, note_term_established/2, sync/0]).

-export([callback_mode/0,
         init/1, handle_event/4, terminate/3]).

-import(chronicle_utils, [get_establish_peers/1,
                          get_establish_quorum/1,
                          get_position/1,
                          get_all_peers/1,
                          get_quorum_peers/1,
                          have_quorum/2,
                          read_timeout/1,
                          send/3,
                          term_number/1]).

-define(NAME, ?MODULE).
-define(SERVER, ?SERVER_NAME(?NAME)).
-define(SERVER(Peer), ?SERVER_NAME(Peer, ?NAME)).

-define(TABLE, ?ETS_TABLE(?MODULE)).
-define(MAX_BACKOFF,
        chronicle_settings:get({leader, max_backoff}, 16)).

-define(EXTRA_WAIT_TIME,
        chronicle_settings:get({leader, extra_wait_time}, 10)).
-define(CHECK_MEMBER_AFTER,
        chronicle_settings:get({leader, check_member_after}, 10000)).
-define(CHECK_MEMBER_TIMEOUT,
        chronicle_settings:get({leader, check_member_timeout}, 10000)).

-record(leader, { peer, history_id, term, status }).
-record(follower, { leader, history_id, term, status }).
-record(observer, { electable, removed }).
-record(voted_for, { peer, ts }).
-record(candidate, {}).
-record(check_member, {}).

-record(data, { %% Since heartbeats are sent frequently, keep a precomputed
                %% list of our peers.
                peers = [],
                live_peers = [],

                history_id = ?NO_HISTORY,
                established_term = ?NO_TERM,

                electable = false,
                removed = false,

                %% election worker in #candidate{} state, membership checker
                %% in #check_member_state{}
                worker,

                %% used to track timers that get auto-canceled when the state
                %% changes
                state_timers = #{},

                leader_waiters = #{},

                backoff_factor = 1,

                check_member_tref
              }).

start_link() ->
    gen_statem:start_link(?START_NAME(?MODULE), ?MODULE, [], []).

get_leader() ->
    leader_info_to_leader(get_leader_info()).

get_leader_info() ->
    case chronicle_ets:get(leader_info) of
        not_found ->
            no_leader;
        {ok, LeaderInfo} ->
            LeaderInfo
    end.

wait_for_leader() ->
    wait_for_leader(5000).

wait_for_leader(Timeout) ->
    wait_for_leader(any, Timeout).

wait_for_leader(Incarnation, Timeout) ->
    case wait_for_leader_fast_path(Incarnation) of
        {_Leader, _LeaderIncarnation} = Result ->
            Result;
        no_leader ->
            wait_for_leader_slow_path(Incarnation, Timeout)
    end.

wait_for_leader_fast_path(Incarnation) ->
    check_leader_incarnation(Incarnation, get_leader()).

wait_for_leader_slow_path(Incarnation, Timeout) ->
    Result = gen_statem:call(
               ?SERVER,
               {wait_for_leader, Incarnation, read_timeout(Timeout)},
               infinity),
    case Result of
        {_Leader, LeaderIncarnation} ->
            true = (LeaderIncarnation =/= Incarnation),
            Result;
        no_leader ->
            exit(no_leader)
    end.

announce_leader_status() ->
    gen_statem:cast(?SERVER, announce_leader_status).

request_vote(Peers, Candidate, HistoryId, Position) ->
    chronicle_utils:send_requests(Peers, ?NAME,
                                  {request_vote, Candidate, HistoryId, Position}).

check_member(Peers, HistoryId, Peer, PeerId, PeerSeqno) ->
    chronicle_utils:send_requests(Peers, ?NAME,
                                  {check_member, HistoryId,
                                   Peer, PeerId, PeerSeqno}).

note_term_finished(HistoryId, Term) ->
    gen_statem:cast(?SERVER, {note_term_status, HistoryId, Term, finished}).

note_term_established(HistoryId, Term) ->
    gen_statem:cast(?SERVER, {note_term_status, HistoryId, Term, established}).

sync() ->
    gen_statem:call(?SERVER, sync, 10000).

%% gen_statem callbacks
callback_mode() ->
    [handle_event_function, state_enter].

init([]) ->
    process_flag(trap_exit, true),
    chronicle_peers:monitor(),

    Self = self(),
    chronicle_events:subscribe(
      fun (Event) ->
              case is_interesting_event(Event) of
                  true ->
                      Self ! {chronicle_event, Event};
                  false ->
                      ok
              end
      end),

    ok = chronicle_ets:register_writer([leader_info]),

    Data =
        case chronicle_agent:get_system_state() of
            {provisioned, Metadata} ->
                metadata2data(Metadata);
            {removed, Metadata} ->
                metadata2data(true, Metadata, #data{});
            {joining_cluster, #metadata{history_id = HistoryId}} ->
                #data{history_id = HistoryId};
            Other ->
                exit({unexpected_state, Other})
        end,

    ping_nodes(Data),
    {ok, make_observer(Data), Data}.

handle_event(enter, OldState, State, Data) ->
    maybe_announce_stepping_down(OldState, State, Data),
    NewData0 = maybe_publish_leader(OldState, State, Data),
    NewData1 = handle_state_leave(OldState, NewData0),
    handle_state_enter(State, NewData1);
handle_event(info, {nodeup, Node, _}, State, Data) ->
    handle_nodeup(Node, State, Data);
handle_event(info, {nodedown, Node, _}, State, Data) ->
    handle_nodedown(Node, State, Data);
handle_event(info, {chronicle_event, Event}, State, Data) ->
    handle_chronicle_event(Event, State, Data);
handle_event(info, {heartbeat, LeaderInfo}, State, Data) ->
    handle_heartbeat(LeaderInfo, State, Data);
handle_event(info, {stepping_down, LeaderInfo}, State, Data) ->
    handle_stepping_down(LeaderInfo, State, Data);
handle_event(info, {'EXIT', Pid, Reason}, State, Data) ->
    handle_process_exit(Pid, Reason, State, Data);
handle_event(info, {timeout, TRef, leader_wait}, State, Data) ->
    handle_leader_wait_timeout(TRef, State, Data);
handle_event(info, {state_timer, Name}, _State, Data) ->
    {ok, _, NewData} = take_state_timer(Name, Data),
    {keep_state, NewData, {next_event, internal, {state_timer, Name}}};
handle_event(info, check_member_timeout, State, Data) ->
    handle_check_member_timeout(State, Data);
handle_event(internal, {state_timer, state}, State, Data) ->
    handle_state_timeout(State, Data);
handle_event(internal, {state_timer, send_heartbeat}, State, Data) ->
    handle_send_heartbeat(State, Data);
handle_event(cast, announce_leader_status, State, Data) ->
    handle_announce_leader_status(State, Data);
handle_event(cast, {note_term_status, HistoryId, Term, Status}, State, Data) ->
    handle_note_term_status(HistoryId, Term, Status, State, Data);
handle_event({call, From},
             {request_vote, Candidate, HistoryId, Position}, State, Data) ->
    handle_request_vote(Candidate, HistoryId, Position, From, State, Data);
handle_event({call, From},
             {check_member, HistoryId, Peer, PeerId, PeerSeqno},
             State, Data) ->
    handle_check_member(HistoryId, Peer, PeerId, PeerSeqno, From, State, Data);
handle_event({call, From},
             {wait_for_leader, Incarnation, Timeout}, State, Data) ->
    handle_wait_for_leader(Incarnation, Timeout, From, State, Data);
handle_event({call, From}, sync, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, _Call, _State, _Data) ->
    {keep_state_and_data, [{reply, From, nack}]};
handle_event(Type, Event, _State, _Data) ->
    ?WARNING("Unexpected event ~p", [{Type, Event}]),
    keep_state_and_data.

terminate(_Reason, State, Data) ->
    _ = handle_state_leave(State, Data),

    case State of
        #leader{} ->
            send_stepping_down(State, Data);
        _ ->
            ok
    end,

    _ = reply_to_leader_waiters(no_leader, Data),
    publish_leader(no_leader),
    announce_leader_status(no_leader).

%% internal
handle_state_leave(_OldState, #data{worker = Worker} = Data) ->
    NewData = cancel_all_state_timers(Data),

    case Worker of
        undefined ->
            NewData;
        _ when is_pid(Worker) ->
            chronicle_utils:terminate_linked_process(Worker, kill),
            NewData#data{worker = undefined}
    end.

maybe_announce_stepping_down(OldState, NewState, Data) ->
    WasLeader = is_record(OldState, leader),
    IsLeader = is_record(NewState, leader),

    case {WasLeader, IsLeader} of
        {true, false} ->
            send_stepping_down(OldState, Data);
        _ ->
            ok
    end.

send_stepping_down(#leader{} = OldState, Data) ->
    {leader, LeaderInfo} = state_leader_info(OldState),
    send_msg_to_live_peers({stepping_down, LeaderInfo}, Data).

handle_state_enter(State, Data) ->
    NewData0 = start_state_timers(State, Data),
    NewData1 = maybe_reset_backoff(State, NewData0),
    NewData2 = handle_check_member_timer(State, NewData1),

    case State of
        #candidate{} ->
            {keep_state, start_election_worker(NewData2)};
        #check_member{} ->
            {keep_state, start_check_member_worker(NewData2)};
        _ ->
            {keep_state, NewData2}
    end.

handle_check_member_timer(State, Data) ->
    case State of
        #leader{} ->
            cancel_check_member_timer(Data);
        #follower{} ->
            cancel_check_member_timer(Data);
        #check_member{} ->
            cancel_check_member_timer(Data);
        #observer{removed = true} ->
            cancel_check_member_timer(Data);
        _ ->
            maybe_start_check_member_timer(Data)
    end.

cancel_check_member_timer(#data{check_member_tref = TRef} = Data) ->
    case TRef of
        undefined ->
            Data;
        _ when is_reference(TRef) ->
            _ = erlang:cancel_timer(TRef),
            ?FLUSH(check_member_timeout),
            Data#data{check_member_tref = undefined}
    end.

maybe_start_check_member_timer(#data{check_member_tref = TRef} = Data) ->
    case TRef of
        undefined ->
            start_check_member_timer(Data);
        _ when is_reference(TRef) ->
            Data
    end.

start_check_member_timer(Data) ->
    TRef = erlang:send_after(?CHECK_MEMBER_AFTER, self(),
                             check_member_timeout),
    Data#data{check_member_tref = TRef}.

start_state_timers(State, Data) ->
    lists:foldl(
      fun (Timer, AccData) ->
              case Timer of
                  send_heartbeat ->
                      %% schedule to send a heartbeat immediately
                      schedule_send_heartbeat(0, AccData);
                  state ->
                      start_state_timer(State, AccData)
              end
      end, Data, state_timers(State)).

state_timers(#leader{}) ->
    [send_heartbeat];
state_timers(#observer{electable = false}) ->
    [];
state_timers(_) ->
    [state].

start_state_timer(State, Data) ->
    start_state_timer(state, get_state_timeout(State, Data), Data).

get_state_timeout(State, Data) ->
    HeartbeatInterval = get_heartbeat_interval(),

    case State of
        #observer{} ->
            get_observer_timeout(HeartbeatInterval, Data);
        #candidate{} ->
            get_candidate_timeout(HeartbeatInterval);
        #check_member{} ->
            ?CHECK_MEMBER_TIMEOUT;
        _ ->
            get_follower_timeout(HeartbeatInterval)
    end.

get_heartbeat_interval() ->
    chronicle_settings:get({leader, heartbeat_interval}, 100).

get_observer_timeout(HeartbeatInterval, Data) ->
    %% This is the timeout that needs to expire before an observer will decide
    %% to attempt to elect itself a leader. The timeout is randomized to avoid
    %% clashes with other nodes.

    BackoffFactor = Data#data.backoff_factor,
    Mult = chronicle_settings:get({leader, observer_multiplier}, 5),
    HeartbeatInterval + rand:uniform(Mult * BackoffFactor * HeartbeatInterval).

get_candidate_timeout(HeartbeatInterval) ->
    %% This is used by the candidate when it starts election. This value is
    %% larger than 'long' timeout, which means that eventually other nodes
    %% will start trying to elect themselves. But this is probably ok.
    Mult = chronicle_settings:get({leader, candidate_multiplier}, 50),
    Mult * HeartbeatInterval.

get_follower_timeout(HeartbeatInterval) ->
    %% This is the amount of time that it will take followers or nodes that
    %% granted their vote to decide that the leader is missing and move to the
    %% observer state.
    Mult = chronicle_settings:get({leader, follower_multiplier}, 20),
    Mult * HeartbeatInterval.

schedule_send_heartbeat(Data) ->
    schedule_send_heartbeat(get_heartbeat_interval(), Data).

schedule_send_heartbeat(Timeout, Data) ->
    start_state_timer(send_heartbeat, Timeout, Data).

is_interesting_event({system_state, provisioned, _}) ->
    true;
is_interesting_event({system_state, removed, _}) ->
    true;
is_interesting_event({new_history, _, _}) ->
    true;
is_interesting_event({term_established, _}) ->
    true;
is_interesting_event({new_config, _, _}) ->
    true;
is_interesting_event(_) ->
    false.

handle_nodeup(Peer, State, Data) ->
    case State of
        #leader{} ->
            send_heartbeat_to_peer(Peer, State);
        _ ->
            ok
    end,
    {keep_state, refresh_live_peers(Data)}.

handle_nodedown(DownPeer, State, Data) ->
    NewData = refresh_live_peers(Data),

    %% If the leader disconnected, become an observer immediately. This has
    %% multiple effects:
    %%   - If the disconnect is permanent, we'll start an election sooner.
    %%   - If the disconnect is intermittent, we'll notify chronicle_rsm-s, so
    %%   they can retry any pending commands immediately after the node
    %%   reconnects back to us.
    ResetState =
        case State of
            #follower{leader = Peer} ->
                Peer =:= DownPeer;
            #voted_for{peer = Peer} ->
                Peer =:= DownPeer;
            _ ->
                false
        end,

    case ResetState of
        true ->
            ?INFO("Peer ~p disconnected when state was ~p. "
                  "Becoming observer.", [DownPeer, state_name(State)]),
            {next_state, make_observer(NewData), NewData};
        false ->
            {keep_state, NewData}
    end.

handle_chronicle_event({system_state, provisioned, Metadata}, State, Data) ->
    handle_provisioned(Metadata, State, Data);
handle_chronicle_event({system_state, removed, Metadata}, State, Data) ->
    handle_removed(Metadata, State, Data);
handle_chronicle_event({new_config, Config, Metadata}, State, Data) ->
    handle_new_config(Config, Metadata, State, Data);
handle_chronicle_event({new_history, HistoryId, Metadata}, State, Data) ->
    handle_new_history(HistoryId, Metadata, State, Data);
handle_chronicle_event({term_established, Term}, State, Data) ->
    handle_new_term(Term, State, Data).

handle_provisioned(Metadata, State, Data) ->
    ?INFO("System became provisioned."),
    NewData = metadata2data(Metadata, Data),
    NewState =
        case State of
            #observer{} ->
                make_observer(NewData);
            _ ->
                State
        end,
    {next_state, NewState, NewData}.

handle_removed(Metadata, State, Data) ->
    ?INFO("Node got removed from the cluster."),
    NewData = metadata2data(true, Metadata, Data),
    case State of
        #leader{} ->
            %% The leader will terminate on it's own accord.
            {keep_state, NewData};
        _ ->
            {next_state, make_observer(NewData), NewData}
    end.

handle_new_config(_Config, Metadata, State, Data) ->
    NewData = metadata2data(Metadata, Data),

    case Data#data.electable =:= NewData#data.electable of
        true ->
            {keep_state, NewData};
        false ->
            case State of
                #leader{} ->
                    %% When we are a leader, we may end up changing our node's
                    %% status making it unelectable. But chronicle_proposer
                    %% will step down in such situation on its own.
                    {keep_state, NewData};
                _ ->
                    ?INFO("Our electability (the new value is ~p) changed. "
                          "Becoming an observer.",
                          [NewData#data.electable]),
                    {next_state, make_observer(NewData), NewData}
            end
    end.

handle_new_history(HistoryId, Metadata, _State, Data) ->
    ?INFO("History changed to ~p. Becoming an observer.", [HistoryId]),
    NewData = metadata2data(Metadata, Data),
    {next_state, make_observer(NewData), NewData}.

handle_new_term(Term, State, Data) ->
    NewData = Data#data{established_term = Term},
    LeaderAndTerm = get_active_leader_and_term(State),
    Invalidate =
        case LeaderAndTerm of
            {_Leader, LeaderTerm} ->
                LeaderTerm =/= Term;
            no_leader ->
                true
        end,

    case Invalidate of
        true ->
            %% Some node established a new term when we either don't know who
            %% the leader is or our leader's term is different from the newly
            %% established one. Reset the state to prevent election timeout
            %% from expiring and interfering with that node. Hopefully we'll
            %% receive a heartbeat from it soon.
            ?INFO("Becoming an observer due to new term being established.~n"
                  "Established term: ~p~n"
                  "Our leader and term: ~p",
                  [Term, LeaderAndTerm]),
            {next_state, make_observer(NewData), NewData};
        false ->
            {keep_state, NewData}
    end.

metadata2data(Metadata) ->
    metadata2data(Metadata, #data{}).

metadata2data(Metadata, Data) ->
    metadata2data(false, Metadata, Data).

metadata2data(Removed, Metadata, Data) ->
    Self = Metadata#metadata.peer,
    SelfId = Metadata#metadata.peer_id,
    ConfigEntry = Metadata#metadata.config,

    QuorumPeers = get_establish_peers(Metadata),
    AllPeers = get_all_peers(Metadata),

    Electable0 = lists:member(Self, QuorumPeers) andalso
        chronicle_config:is_peer(Self, SelfId, ConfigEntry#log_entry.value),
    Electable = not Removed andalso Electable0,

    NewData = Data#data{history_id = chronicle_agent:get_history_id(Metadata),
                        established_term = Metadata#metadata.term,
                        peers = AllPeers -- [Self],
                        electable = Electable,
                        removed = Removed},

    refresh_live_peers(NewData).

handle_note_term_status(HistoryId, Term, Status, State, Data) ->
    case check_is_leader(HistoryId, Term, State) of
        ok ->
            case Status of
                finished ->
                    ?INFO("Term ~p has finished. Stepping down.", [Term]),
                    {next_state, make_observer(Data), Data};
                established ->
                    ?INFO("Term ~p established.", [Term]),
                    tentative = State#leader.status,
                    NewState = State#leader{status = Status},
                    {next_state, NewState, Data}
            end;
        {error, _} = Error ->
            ?DEBUG("Ignoring stale term status ~p: ~p",
                   [{HistoryId, Term, Status}, Error]),
            keep_state_and_data
    end.

handle_state_timeout(State, Data) ->
    ?DEBUG("State timeout when state is: ~p", [State]),

    NewState =
        case State of
            #observer{} ->
                #candidate{};
            _ ->
                make_observer(Data)
        end,

    {next_state, NewState, Data}.

handle_heartbeat(LeaderInfo, State, Data) ->
    #{leader := Peer,
      history_id := HistoryId,
      term := Term,
      status := Status} = LeaderInfo,

    case ?CHECK(check_history_id(HistoryId, Data),
                check_accept_heartbeat(Term, Status, State, Data)) of
        ok ->
            NewState = #follower{leader = Peer,
                                 history_id = HistoryId,
                                 term = Term,
                                 status = Status},

            {next_state, NewState,
             %% We've received a heartbeat, so start the election timer anew.
             start_state_timer(NewState, Data)};
        _Error ->
            keep_state_and_data
    end.

handle_stepping_down(LeaderInfo, State, Data) ->
    #{leader := Peer} = LeaderInfo,

    case State of
        #follower{leader = OurLeader}
          when Peer =:= OurLeader ->
            %% We don't check the history and term numbers. That's because
            %% heartbeats and stepping_down messages originate on the same
            %% node and there shouldn't be any reordering happening in
            %% transition.
            ?INFO("Leader ~p told us it's stepping down.~n"
                  "Full leader info: ~p",
                  [Peer, LeaderInfo]),
            {next_state, make_observer(Data), Data};
        _ ->
            keep_state_and_data
    end.

handle_process_exit(Pid, Reason, State,
                    #data{worker = Worker} = Data) ->
    case Pid =:= Worker of
        true ->
            handle_worker_exit(Reason, State, Data);
        false ->
            {stop, {linked_process_died, Pid, Reason}}
    end.

handle_worker_exit(Reason, State, Data) ->
    Result =
        case Reason of
            {shutdown, {worker_result, R}} ->
                R;
            _ ->
                {error, {worker_crashed, Reason}}
        end,

    NewData = Data#data{worker = undefined},

    case State of
        #candidate{} ->
            handle_election_result(Result, NewData);
        #check_member{} ->
            handle_check_member_result(Result, NewData)
    end.

handle_election_result(Result, Data) ->
    case Result of
        {ok, Peer, HistoryId, Term} ->
            NewTerm = chronicle_utils:next_term(Term, Peer),
            ?INFO("Going to become a leader in term ~p (history id ~p)",
                  [NewTerm, HistoryId]),
            NewState = #leader{peer = Peer,
                               history_id = HistoryId,
                               term = NewTerm,
                               status = tentative},
            {next_state, NewState, Data};
        {error, _} = Error ->
            ?INFO("Election failed: ~p", [Error]),
            {next_state, make_observer(Data), backoff(Data)}
    end.

handle_check_member_result(Result, Data) ->
    case Result of
        ok ->
            ok;
        {removed, Peer, Self, SelfId} ->
            ?INFO("Detected that we got "
                  "removed from the cluster via node ~p", [Peer]),
            case chronicle_agent:mark_removed(Self, SelfId) of
                ok ->
                    ok;
                {error, Error} ->
                    ?WARNING("Failed to mark node removed: ~p", [Error])
            end;
        {error, Error} ->
            ?WARNING("Failed to check membership status: ~w", [Error])
    end,

    {next_state, make_observer(Data), Data}.

handle_request_vote(Candidate, HistoryId, Position, From, State, Data) ->
    case check_grant_vote(HistoryId, Position, State) of
        {ok, LatestTerm} ->
            {next_state,
             #voted_for{peer = Candidate,
                        ts = erlang:system_time()}, Data,
             {reply, From, {ok, LatestTerm}}};
        {error, _} = Error ->
            {keep_state_and_data, {reply, From, Error}}
    end.

check_consider_granting_vote(State) ->
    case State of
        #observer{} ->
            ok;
        #voted_for{} ->
            ok;
        #candidate{} ->
            {error, in_election};
        #check_member{} ->
            {error, check_member};
        _ ->
            {error, {have_leader, state_leader_info(State)}}
    end.

check_grant_vote(HistoryId, PeerPosition, State) ->
    case check_consider_granting_vote(State) of
        ok ->
            chronicle_agent:check_grant_vote(HistoryId, PeerPosition);
        {error, _} = Error ->
            Error
    end.

handle_check_member_timeout(_State, Data) ->
    {next_state, #check_member{}, Data}.

start_check_member_worker(Data) ->
    Pid = proc_lib:spawn_link(fun check_member_worker/0),
    Data#data{worker = Pid}.

-spec check_member_worker() -> no_return().
check_member_worker() ->
    Result = do_check_member_worker(),
    exit({shutdown, {worker_result, Result}}).

do_check_member_worker() ->
    case chronicle_agent:get_system_state() of
        {provisioned, Metadata} ->
            do_check_member_worker(Metadata);
        _ ->
            ok
    end.

do_check_member_worker(Metadata) ->
    HistoryId = chronicle_agent:get_history_id(Metadata),
    HighSeqno = Metadata#metadata.high_seqno,
    Self = Metadata#metadata.peer,
    SelfId = Metadata#metadata.peer_id,
    Peers = get_all_peers(Metadata),

    OtherPeers = Peers -- [Self],

    case OtherPeers of
        [] ->
            ok;
        _ ->
            CheckPeers = lists:sublist(chronicle_utils:shuffle(OtherPeers), 5),
            ReqIds = check_member(CheckPeers, HistoryId, Self, SelfId, HighSeqno),
            case check_member_worker_loop(ReqIds) of
                ok ->
                    ok;
                {removed, Peer} ->
                    {removed, Peer, Self, SelfId}
            end
    end.

check_member_worker_loop(ReqIds) ->
    case gen_statem:receive_response(ReqIds, infinity, true) of
        no_request ->
            ok;
        {Response, Peer, NewReqIds} ->
            Result =
                case Response of
                    {reply, Reply} ->
                        Reply;
                    {error, {Reason, _}} ->
                        {error, {down, chronicle_utils:sanitize_reason(Reason)}}
                end,

            case Result of
                {ok, true} ->
                    check_member_worker_loop(NewReqIds);
                {ok, false} ->
                    %% other responses will not get cleaned up, but as we are
                    %% running in a subprocess, that does not matter
                    {removed, Peer};
                Error ->
                    ?DEBUG("Failed to check membership status on peer ~p: ~p",
                           [Peer, Error]),
                    check_member_worker_loop(NewReqIds)
            end
    end.

handle_check_member(HistoryId, Peer, PeerId, PeerSeqno, From, _State, _Data) ->
    Reply = chronicle_agent:check_member(HistoryId, Peer, PeerId, PeerSeqno),
    {keep_state_and_data, {reply, From, Reply}}.

handle_wait_for_leader(Incarnation, Timeout, From, State, Data) ->
    case check_leader_incarnation(Incarnation, state_leader(State)) of
        {_Leader, _LeaderIncarnation} = Reply ->
            {keep_state_and_data, {reply, From, Reply}};
        no_leader ->
            NewData = add_leader_waiter(Incarnation, Timeout, From, Data),
            {keep_state, NewData}
    end.

handle_leader_wait_timeout(TRef, State,
                           #data{leader_waiters = Waiters} = Data) ->
    {{From, Incarnation}, NewWaiters} = maps:take(TRef, Waiters),
    no_leader = check_leader_incarnation(Incarnation, state_leader(State)),
    gen_statem:reply(From, no_leader),
    {keep_state, Data#data{leader_waiters = NewWaiters}}.

add_leader_waiter(Incarnation, Timeout,
                  From, #data{leader_waiters = Waiters} = Data) ->
    TRef = erlang:start_timer(Timeout, self(), leader_wait),
    NewWaiters = Waiters#{TRef => {From, Incarnation}},
    Data#data{leader_waiters = NewWaiters}.

maybe_reply_to_leader_waiters(LeaderInfo, Data) ->
    case leader_info_to_leader(LeaderInfo) of
        no_leader ->
            Data;
        {_Leader, _LeaderIncarnation} = Reply ->
            reply_to_leader_waiters(Reply, Data)
    end.

reply_to_leader_waiters(Reply, #data{leader_waiters = Waiters} = Data) ->
    maps:foreach(
      fun (TRef, {From, _}) ->
              gen_statem:reply(From, Reply),
              _ = erlang:cancel_timer(TRef),
              ?FLUSH({timeout, TRef, _})
      end, Waiters),

    Data#data{leader_waiters = #{}}.

start_election_worker(Data) ->
    Pid = proc_lib:spawn_link(fun election_worker/0),
    Data#data{worker = Pid}.

-spec election_worker() -> no_return().
election_worker() ->
    Result = do_election_worker(),
    exit({shutdown, {worker_result, Result}}).

do_election_worker() ->
    Metadata = chronicle_agent:get_metadata(),

    LatestTerm = Metadata#metadata.term,
    HistoryId = chronicle_agent:get_history_id(Metadata),
    Position = get_position(Metadata),
    Quorum = get_establish_quorum(Metadata),
    Peers = get_quorum_peers(Quorum),

    ?INFO("Starting election.~n"
          "History ID: ~p~n"
          "Log position: ~p~n"
          "Peers: ~p~n"
          "Required quorum: ~p",
          [HistoryId, Position, Peers, Quorum]),

    Leader = Metadata#metadata.peer,
    OtherPeers = Peers -- [Leader],

    case lists:member(Leader, Peers) of
        true ->
            case OtherPeers =:= [] of
                true ->
                    ?INFO("I'm the only peer, so I'm the leader."),
                    {ok, Leader, HistoryId, LatestTerm};
                false ->
                    ReqIds = request_vote(OtherPeers,
                                          Leader, HistoryId, Position),
                    case election_worker_loop(ReqIds,
                                              Quorum, [Leader], LatestTerm) of
                        {ok, FinalTerm} ->
                            {ok, Leader, HistoryId, FinalTerm};
                        {error, _} = Error ->
                            Error
                    end
            end;
        false ->
            {error, {not_voter, Leader, Peers}}
    end.

election_worker_loop(ReqIds, Quorum, Votes, Term) ->
    case gen_statem:receive_response(ReqIds, infinity, true) of
        no_request ->
            {error, {no_quorum, Votes, Term}};
        {Response, Peer, NewReqIds} ->
            Result =
                case Response of
                    {reply, Reply} ->
                        Reply;
                    {error, {Reason, _}} ->
                        {error, {down, chronicle_utils:sanitize_reason(Reason)}}
                end,

            case Result of
                {ok, PeerTerm} ->
                    NewVotes = [Peer | Votes],
                    NewTerm = max(Term, PeerTerm),

                    case have_quorum(NewVotes, Quorum) of
                        true ->
                            election_worker_extra_wait(NewTerm, NewReqIds);
                        false ->
                            election_worker_loop(NewReqIds,
                                                 Quorum, NewVotes, NewTerm)
                    end;
                Error ->
                    ?DEBUG("Failed to get leader vote from ~p: ~p", [Peer, Error]),
                    election_worker_loop(NewReqIds, Quorum, Votes, Term)
            end
    end.

election_worker_extra_wait(Term, ReqIds) ->
    Deadline = erlang:monotonic_time(millisecond) + ?EXTRA_WAIT_TIME,
    election_worker_extra_wait_loop(Term, ReqIds, {abs, Deadline}).

election_worker_extra_wait_loop(Term, ReqIds, Timeout) ->
    case gen_statem:receive_response(ReqIds, Timeout, true) of
        no_request ->
            {ok, Term};
        timeout ->
            {ok, Term};
        {Response, _, NewReqIds} ->
            NewTerm =
                case Response of
                    {reply, {ok, PeerTerm}} ->
                        max(Term, PeerTerm);
                    _ ->
                        Term
                end,
            election_worker_extra_wait_loop(NewTerm, NewReqIds, Timeout)
    end.

handle_send_heartbeat(State, Data) ->
    send_heartbeat(State, Data),
    {keep_state, schedule_send_heartbeat(Data)}.

make_heartbeat(#leader{} = State) ->
    {leader, LeaderInfo} = state_leader_info(State),
    {heartbeat, LeaderInfo}.

send_heartbeat(State, Data) ->
    send_msg_to_live_peers(make_heartbeat(State), Data).

send_heartbeat_to_peer(Peer, State) ->
    send_msg(Peer, make_heartbeat(State)).

send_msg_to_live_peers(Msg, #data{live_peers = Peers}) ->
    send_msg_to_peers(Peers, Msg).

send_msg_to_peers(Peers, Msg) ->
    lists:foreach(
      fun (Peer) ->
              send_msg(Peer, Msg)
      end, Peers).

send_msg(Peer, Msg) ->
    send(?SERVER(Peer), Msg, [noconnect, nosuspend]).

handle_announce_leader_status(State, _Data) ->
    announce_leader_status(state_leader_info(State)),
    keep_state_and_data.

maybe_publish_leader(OldState, State, Data) ->
    OldLeaderInfo = state_leader_info(OldState),
    NewLeaderInfo = state_leader_info(State),

    case OldLeaderInfo =:= NewLeaderInfo of
        true ->
            Data;
        false ->
            publish_leader(NewLeaderInfo),
            announce_leader_status(NewLeaderInfo),
            maybe_reply_to_leader_waiters(NewLeaderInfo, Data)
    end.

check_history_id(HistoryId, #data{history_id = OurHistoryId}) ->
    do_check_history_id(HistoryId, OurHistoryId).

do_check_history_id(TheirHistoryId, OurHistoryId) ->
    case TheirHistoryId =:= OurHistoryId of
        true ->
            ok;
        false ->
            {error, {history_mismatch, OurHistoryId}}
    end.

check_is_leader(HistoryId, Term,
                #leader{history_id = OurHistoryId, term = OurTerm}) ->
    case HistoryId =:= OurHistoryId andalso Term =:= OurTerm of
        true ->
            ok;
        false ->
            {error, {wrong_term, Term, OurTerm}}
    end;
check_is_leader(_HistoryId, _Term, State) ->
    {error, {not_a_leader, state_name(State)}}.

check_accept_heartbeat(NewTerm, NewStatus, State, Data) ->
    {OurTerm, OurStatus} = get_last_known_leader_term(State, Data),

    case NewTerm =:= OurTerm of
        true ->
            %% This should be the most common case, so accept the hearbeat
            %% quickly.
            ok;
        false ->
            NewTermNumber = term_number(NewTerm),
            OurTermNumber = term_number(OurTerm),

            if
                NewTermNumber > OurTermNumber ->
                    ok;
                NewTermNumber =:= OurTermNumber ->
                    %% Two nodes are competing to become a leader in the same
                    %% term.
                    case {NewStatus, OurStatus} of
                        {established, _} ->
                            %% The node we got the heartbeat from successfully
                            %% established the term on a quorum of nodes. So
                            %% we accept it. Our term status then must not be
                            %% established.
                            true = (OurStatus =/= established),
                            ok;
                        {tentative, inactive} ->
                            %% Accept a tentative heartbeat only if we haven't
                            %% heard from any other leader before.
                            ok;
                        _ ->
                            {error, {have_leader,
                                     NewTerm, NewStatus,
                                     OurTerm, OurStatus}}
                    end;
                true ->
                    {error, {stale_term, NewTerm, OurTerm}}
            end
    end.

get_last_known_leader_term(State, Data) ->
    %% For a short period of time, the leader term that we've received via a
    %% heartbeat may be ahead of the established term.
    case state_leader_info(State) of
        {_, #{term := Term, status := Status}} ->
            {Term, Status};
        no_leader ->
            {Data#data.established_term, inactive}
    end.

state_name(State) ->
    element(1, State).

start_state_timer(Name, Timeout, Data) ->
    NewData = cancel_state_timer(Name, Data),
    #data{state_timers = StateTimers} = NewData,
    TRef = erlang:send_after(Timeout, self(), {state_timer, Name}),
    NewData#data{state_timers = StateTimers#{Name => TRef}}.

take_state_timer(Name, #data{state_timers = Timers} = Data) ->
    case maps:take(Name, Timers) of
        {TRef, NewTimers} ->
            {ok, TRef, Data#data{state_timers = NewTimers}};
        error ->
            not_found
    end.

cancel_state_timer(Name, Data) ->
    case take_state_timer(Name, Data) of
        {ok, TRef, NewData} ->
            cancel_state_timer_tref(TRef, Name),
            NewData;
        not_found ->
            Data
    end.

cancel_state_timer_tref(TRef, Name) ->
    _ = erlang:cancel_timer(TRef),
    receive
        {state_timer, Name} ->
            ok
    after
        0 ->
            ok
    end.

cancel_all_state_timers(#data{state_timers = StateTimers} = Data) ->
    maps:foreach(
      fun (Name, TRef) ->
              cancel_state_timer_tref(TRef, Name)
      end, StateTimers),
    Data#data{state_timers = #{}}.

state_leader(State) ->
    leader_info_to_leader(state_leader_info(State)).

state_leader_info(State) ->
    case State of
        #leader{peer = Peer,
                history_id = HistoryId, term = Term, status = Status} ->
            {leader, make_leader_info(Peer, HistoryId, Term, Status)};
        #follower{leader = Leader,
                  history_id = HistoryId,
                  term = Term,
                  status = Status} ->
            {follower, make_leader_info(Leader, HistoryId, Term, Status)};
        _ ->
            no_leader
    end.

leader_info_to_leader(no_leader) ->
    no_leader;
leader_info_to_leader({_, #{leader := Leader,
                            history_id := HistoryId,
                            term := Term,
                            status := Status}}) ->
    case Status of
        established ->
            %% Expose only established leaders to clients
            {Leader, {HistoryId, Term}};
        _ ->
            no_leader
    end.

check_leader_incarnation(_, no_leader) ->
    no_leader;
check_leader_incarnation(any, {_Leader, _LeaderIncarnation} = Result) ->
    Result;
check_leader_incarnation(Incarnation, {_Leader, LeaderIncarnation} = Result) ->
    case Incarnation =/= LeaderIncarnation of
        true ->
            Result;
        false ->
            no_leader
    end.

make_leader_info(Leader, HistoryId, Term, Status) ->
    #{leader => Leader,
      history_id => HistoryId,
      term => Term,
      status => Status}.

publish_leader(LeaderInfo) ->
    chronicle_ets:put(leader_info, LeaderInfo).

announce_leader_status(Status) ->
    chronicle_events:sync_notify({leader_status, Status}).

get_active_leader_and_term(State) ->
    case state_leader_info(State) of
        {_, #{leader := Leader, term := LeaderTerm}} ->
            true = (LeaderTerm =/= undefined),
            {Leader, LeaderTerm};
        _ ->
            no_leader
    end.

make_observer(#data{electable = Electable, removed = Removed}) ->
    #observer{electable = Electable, removed = Removed}.

backoff(#data{backoff_factor = Factor} = Data) ->
    case Factor >= ?MAX_BACKOFF of
        true ->
            Data;
        false ->
            Data#data{backoff_factor = Factor * 2}
    end.

reset_backoff(Data) ->
    Data#data{backoff_factor = 1}.

maybe_reset_backoff(State, Data) ->
    Reset =
        case State of
            #voted_for{} ->
                true;
            #follower{} ->
                true;
            #leader{} ->
                true;
            _ ->
                false
        end,

    case Reset of
        true ->
            reset_backoff(Data);
        false ->
            Data
    end.

refresh_live_peers(#data{peers = Peers} = Data) ->
    LivePeers = chronicle_peers:get_live_peers(Peers),
    Data#data{live_peers = LivePeers}.

ping_nodes(#data{peers = Peers, live_peers = LivePeers}) ->
    PingPeers = Peers -- LivePeers,
    case PingPeers of
        [] ->
            ok;
        _ ->
            ?DEBUG("Pinging some peers: ~w", [Peers]),
            lists:foreach(
              fun (Peer) ->
                      spawn(
                        fun () ->
                                Result = net_kernel:connect_node(Peer),
                                ?DEBUG("Pinged ~p: ~p", [Peer, Result])
                        end)
              end, PingPeers)
    end.
