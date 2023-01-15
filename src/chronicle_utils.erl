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
-module(chronicle_utils).

-include_lib("kernel/include/file.hrl").
-include("chronicle.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([groupby_map/2,
         terminate/2, wait_for_process/2,
         terminate_and_wait/2, terminate_linked_process/2,
         next_term/2,
         send/3,
         call/2, call/3, call/4,
         send_requests/3, multi_call/4, multi_call/5,
         start_timeout/1, read_timeout/1, read_deadline/1,
         term_number/1, term_leader/1,
         get_position/1, compare_positions/2, max_position/2,
         monitor_process/1, monitor_process/2,
         make_batch/2, batch_enq/2, batch_flush/1, batch_map/2,
         gb_trees_filter/2,
         random_uuid/0,
         get_config/1, get_all_peers/1,
         get_establish_quorum/1, get_establish_peers/1, get_quorum_peers/1,
         have_quorum/2, is_quorum_feasible/3,
         sync_dir/1,
         atomic_write_file/2,
         create_marker/1, create_marker/2, delete_marker/1,
         mkdir_p/1, check_file_exists/2, delete_recursive/1,
         read_full/2,
         queue_foreach/2, queue_takefold/3,
         queue_takewhile/2, queue_dropwhile/2,
         log_entry_revision/1,
         sanitize_entry/1, sanitize_entries/1,
         sanitize_stacktrace/1, sanitize_reason/1,
         shuffle/1,
         announce_important_change/1,
         is_function_exported/3,
         read_int_from_file/2, store_int_to_file/2]).

-export_type([batch/0, send_options/0, send_result/0, multi_call_result/2]).

groupby_map(Fun, List) ->
    lists:foldl(
      fun (Elem, Acc) ->
              {Key, Value} = Fun(Elem),
              maps:update_with(
                Key,
                fun (Values) ->
                        [Value | Values]
                end, [Value], Acc)
      end, #{}, List).

terminate(Pid, normal) ->
    terminate(Pid, shutdown);
terminate(Pid, Reason) ->
    exit(Pid, Reason).

wait_for_process(PidOrName, Timeout) ->
    MRef = erlang:monitor(process, PidOrName),
    receive
        {'DOWN', MRef, process, _, _Reason} ->
            ok
    after Timeout ->
            erlang:demonitor(MRef, [flush]),
            {error, timeout}
    end.

-ifdef(TEST).
wait_for_process_test_() ->
    {spawn,
     fun () ->
             %% Normal
             ok = wait_for_process(spawn(fun() -> ok end), 100),
             %% Timeout
             {error, timeout} =
                 wait_for_process(spawn(fun() ->
                                                timer:sleep(100), ok end),
                                  1),
             %% Process that exited before we went.
             Pid = spawn(fun() -> ok end),
             ok = wait_for_process(Pid, 100),
             ok = wait_for_process(Pid, 100)
     end}.
-endif.

terminate_and_wait(Pid, Reason) when is_pid(Pid) ->
    terminate(Pid, Reason),
    ok = wait_for_process(Pid, infinity).

terminate_linked_process(Pid, Reason) when is_pid(Pid) ->
    with_trap_exit(
      fun () ->
              terminate(Pid, Reason),
              unlink(Pid),
              ?FLUSH({'EXIT', Pid, _})
      end),

    ok = wait_for_process(Pid, infinity).

with_trap_exit(Fun) ->
    Old = process_flag(trap_exit, true),
    try
        Fun()
    after
        case Old of
            true ->
                ok;
            false ->
                process_flag(trap_exit, false),
                with_trap_exit_maybe_exit()
        end
    end.

with_trap_exit_maybe_exit() ->
    receive
        {'EXIT', _Pid, normal} = Exit ->
            ?DEBUG("Ignoring exit message with reason normal: ~p", [Exit]),
            with_trap_exit_maybe_exit();
        {'EXIT', Pid, Reason} ->
            ?DEBUG("Terminating due to ~p terminating with reason ~p",
                   [Pid, sanitize_reason(Reason)]),
            %% exit/2 is used instead of exit/1, so it can't be caught by a
            %% try..catch block.
            exit(self(), Reason)
    after
        0 ->
            ok
    end.

next_term({TermNo, _}, Peer) ->
    {TermNo + 1, Peer}.

-type send_options() :: [nosuspend | noconnect].
-type send_result() :: ok | nosuspend | noconnect.

-spec send(any(), any(), send_options()) -> send_result().
-ifdef(TEST).
send(Name, Msg, Options) ->
    {via, vnet, _} = Name,
    try
        vnet:send(element(3, Name), Msg),
        ok
    catch
        exit:{badarg, {_, _}} ->
            %% vnet:send() may fail with this error when Name can't be
            %% resolved. This is different from how erlang:send/3 behaves, so
            %% we are just catching the error.

            %% Force dialyzer to believe that nosuspend and noconnect
            %% are valid return values.
            case Options of
                [] ->
                    ok;
                [Other|_]->
                    Other
            end
    end.
-else.
send(Name, Msg, Options) ->
    erlang:send(Name, Msg, Options).
-endif.

call(ServerRef, Call) ->
    call(ServerRef, Call, 5000).

%% A version of gen_{server,statem}:call/3 function that can take a timeout in
%% the form of {timeout, StartTime, Timeout} tuple in place of a literal timeout
%% value.
call(ServerRef, Call, Timeout) ->
    call(ServerRef, Call, Call, Timeout).

call(ServerRef, Call, LoggedCall, Timeout) ->
    do_call(ServerRef, Call, LoggedCall, read_timeout(Timeout)).

do_call(ServerRef, Call, LoggedCall, Timeout) ->
    try gen_statem:call(ServerRef, Call, Timeout)
    catch
        Class:Reason:Stack ->
            erlang:raise(
              Class,
              {sanitize_reason(Reason),
               {gen_statem, call, [ServerRef, LoggedCall, Timeout]}},
              sanitize_stacktrace(Stack))
    end.

-spec send_requests([chronicle:peer()],
                    Name::atom(),
                    Request::term()) ->
          gen_statem:request_id_collection().
send_requests(Peers, Name, Request) ->
    lists:foldl(
      fun (Peer, ReqIds) ->
              ServerRef = ?SERVER_NAME(Peer, Name),
              gen_statem:send_request(ServerRef, Request, Peer, ReqIds)
      end, gen_statem:reqids_new(), Peers).

-type multi_call_error() :: {down, Reason::any()} | timeout.
-type multi_call_result() :: multi_call_result(any(), any()).
-type multi_call_result(Ok, Bad) ::
        {#{chronicle:peer() => Ok},
         #{chronicle:peer() => Bad | multi_call_error()}}.
-type multi_call_pred() :: fun ((Result::any()) -> boolean()).

-spec multi_call([chronicle:peer()],
                 Name::atom(),
                 Request::term(),
                 timeout()) ->
          multi_call_result().
multi_call(Peers, Name, Request, Timeout) ->
    multi_call(Peers, Name, Request,
               fun (_) -> true end,
               Timeout).

-spec multi_call([chronicle:peer()],
                 Name::atom(),
                 Request::term(),
                 OkPred::multi_call_pred(),
                 timeout()) ->
          multi_call_result().
multi_call(Peers, Name, Request, OkPred, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    ReqIds = send_requests(Peers, Name, Request),
    multi_call_recv(ReqIds, {abs, Deadline}, OkPred, #{}, #{}).

multi_call_recv(ReqIds, Timeout, OkPred, AccOk, AccBad) ->
    case gen_statem:receive_response(ReqIds, Timeout, true) of
        no_request ->
            {AccOk, AccBad};
        timeout ->
            NewAccBad =
                lists:foldl(fun ({_, Peer}, Acc) ->
                                    Acc#{Peer => timeout}
                            end, AccBad, gen_statem:reqids_to_list(ReqIds)),
            {AccOk, NewAccBad};
        {Response, Peer, NewReqIds} ->
            case Response of
                {reply, Reply} ->
                    {NewAccOk, NewAccBad} =
                        case OkPred(Reply) of
                            true ->
                                {AccOk#{Peer => Reply}, AccBad};
                            false ->
                                {AccOk, AccBad#{Peer => Reply}}
                        end,
                    multi_call_recv(NewReqIds, Timeout, OkPred,
                                    NewAccOk, NewAccBad);
                {error, {Reason, _}} ->
                    NewAccBad = AccBad#{Peer => {down, sanitize_reason(Reason)}},
                    multi_call_recv(NewReqIds, Timeout, OkPred, AccOk, NewAccBad)
            end
    end.

start_timeout({deadline, _} = Deadline) ->
    Deadline;
start_timeout(infinity) ->
    infinity;
start_timeout(Timeout)
  when is_integer(Timeout), Timeout >= 0 ->
    NowTs = erlang:monotonic_time(millisecond),
    {deadline, NowTs + Timeout}.

read_timeout({deadline, Deadline}) ->
    NowTs = erlang:monotonic_time(millisecond),
    max(0, Deadline - NowTs);
read_timeout(infinity) ->
    infinity;
read_timeout(Timeout) when is_integer(Timeout) ->
    Timeout.

read_deadline({deadline, Deadline}) ->
    Deadline;
read_deadline(infinity) ->
    infinity;
read_deadline(Timeout) when is_integer(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

term_number({TermNumber, _TermLeader}) ->
    TermNumber.

term_leader({_TermNumber, TermLeader}) ->
    TermLeader.

get_position(#metadata{high_term = HighTerm, high_seqno = HighSeqno}) ->
    {HighTerm, HighSeqno}.

compare_positions({TermVotedA, HighSeqnoA}, {TermVotedB, HighSeqnoB}) ->
    TermVotedNoA = term_number(TermVotedA),
    TermVotedNoB = term_number(TermVotedB),

    if
        TermVotedNoA > TermVotedNoB ->
            gt;
        TermVotedNoA =:= TermVotedNoB ->
            true = (TermVotedA =:= TermVotedB),

            if
                HighSeqnoA > HighSeqnoB ->
                    gt;
                HighSeqnoA =:= HighSeqnoB ->
                    eq;
                true ->
                    lt
            end;
        true ->
            lt
    end.

max_position(PositionA, PositionB) ->
    case compare_positions(PositionA, PositionB) of
        gt ->
            PositionA;
        _ ->
            PositionB
    end.

%% A version of erlang:monitor(process, ...) that knows how to deal with {via,
%% Registry, Name} processes that are used by vnet.
monitor_process(What) ->
    monitor_process(What, []).

monitor_process({via, Registry, Name}, Options) ->
    assert_is_test(),

    case Registry:whereis_name(Name) of
        undefined ->
            MRef = make_ref(),

            %% This is malformed DOWN message because there's no Pid or a
            %% process name included. The caller MUST node use it. It's only
            %% meant to be used for tests, so it's ok.
            self() ! {'DOWN', MRef, process, undefined, noproc},
            MRef;
        Pid when is_pid(Pid) ->
            monitor_process(Pid, Options)
    end;
monitor_process(Process, Options) ->
    erlang:monitor(process, Process, Options).

-ifdef(TEST).
assert_is_test() ->
    ok.
-else.
-spec assert_is_test() -> no_return().
assert_is_test() ->
    error(not_test).
-endif.

-record(batch, { id :: any(),
                 reqs :: list(),
                 timer :: undefined | reference(),
                 max_age :: non_neg_integer() }).

-type batch() :: #batch{}.

make_batch(Id, MaxAge) ->
    #batch{id = Id,
           reqs = [],
           max_age = MaxAge}.

batch_enq(Req, #batch{id = Id,
                      reqs = Reqs,
                      timer = Timer,
                      max_age = MaxAge} = Batch) ->
    NewTimer =
        case Timer of
            undefined ->
                erlang:send_after(MaxAge, self(), {batch_ready, Id});
            _ when is_reference(Timer) ->
                Timer
        end,

    Batch#batch{reqs = [Req | Reqs], timer = NewTimer}.

batch_flush(#batch{id = Id,
                   reqs = Reqs,
                   timer = Timer} = Batch) ->
    case Timer of
        undefined ->
            ok;
        _ when is_reference(Timer) ->
            _ = erlang:cancel_timer(Timer),
            ?FLUSH({batch_ready, Id}),
            ok
    end,
    {lists:reverse(Reqs),
     Batch#batch{reqs = [], timer = undefined}}.

batch_map(Fun, #batch{reqs = Requests} = Batch) ->
    Batch#batch{reqs = Fun(Requests)}.

gb_trees_filter(Pred, Tree) ->
    Iter = gb_trees:iterator(Tree),
    gb_trees_filter_loop(Pred, Iter, []).

gb_trees_filter_loop(Pred, Iter, Acc) ->
    case gb_trees:next(Iter) of
        {Key, Value, NewIter} ->
            NewAcc =
                case Pred(Key, Value) of
                    true ->
                        [{Key, Value} | Acc];
                    false ->
                        Acc
                end,

            gb_trees_filter_loop(Pred, NewIter, NewAcc);
        none ->
            gb_trees:from_orddict(lists:reverse(Acc))
    end.

-ifdef(TEST).
gb_trees_filter_test() ->
    IsEven = fun (Key, _Value) ->
                     Key rem 2 =:= 0
             end,

    Tree = gb_trees:from_orddict([{1,2}, {2,3}, {3,4}, {4,5}]),
    ?assertEqual([{2,3}, {4,5}],
                 gb_trees:to_list(gb_trees_filter(IsEven, Tree))),

    ?assertEqual([],
                 gb_trees:to_list(gb_trees_filter(IsEven, gb_trees:empty()))).

-endif.

random_uuid() ->
    hexify(crypto:strong_rand_bytes(16)).

hexify(Binary) ->
    << <<(hexify_digit(High)), (hexify_digit(Low))>>
       || <<High:4, Low:4>> <= Binary >>.

hexify_digit(0) -> $0;
hexify_digit(1) -> $1;
hexify_digit(2) -> $2;
hexify_digit(3) -> $3;
hexify_digit(4) -> $4;
hexify_digit(5) -> $5;
hexify_digit(6) -> $6;
hexify_digit(7) -> $7;
hexify_digit(8) -> $8;
hexify_digit(9) -> $9;
hexify_digit(10) -> $a;
hexify_digit(11) -> $b;
hexify_digit(12) -> $c;
hexify_digit(13) -> $d;
hexify_digit(14) -> $e;
hexify_digit(15) -> $f.

get_config(#metadata{config = ConfigEntry}) ->
    ConfigEntry#log_entry.value.

get_all_peers(Metadata) ->
    case Metadata#metadata.pending_branch of
        undefined ->
            chronicle_config:get_peers(get_config(Metadata));
        #branch{peers = BranchPeers} ->
            BranchPeers
    end.

get_establish_quorum(Metadata) ->
    case Metadata#metadata.pending_branch of
        undefined ->
            chronicle_config:get_quorum(get_config(Metadata));
        #branch{peers = BranchPeers} ->
            {all, sets:from_list(BranchPeers)}
    end.

get_establish_peers(Metadata) ->
    get_quorum_peers(get_establish_quorum(Metadata)).

get_quorum_peers(Quorum) ->
    sets:to_list(do_get_quorum_peers(Quorum)).

do_get_quorum_peers({majority, Peers}) ->
    Peers;
do_get_quorum_peers({all, Peers}) ->
    Peers;
do_get_quorum_peers({joint, Quorum1, Quorum2}) ->
    sets:union(do_get_quorum_peers(Quorum1),
               do_get_quorum_peers(Quorum2)).

have_quorum(AllVotes, Quorum)
  when is_list(AllVotes) ->
    do_have_quorum(sets:from_list(AllVotes), Quorum);
have_quorum(AllVotes, Quorum) ->
    do_have_quorum(AllVotes, Quorum).

do_have_quorum(AllVotes, {joint, Quorum1, Quorum2}) ->
    do_have_quorum(AllVotes, Quorum1) andalso do_have_quorum(AllVotes, Quorum2);
do_have_quorum(AllVotes, {all, QuorumNodes}) ->
    MissingVotes = sets:subtract(QuorumNodes, AllVotes),
    sets:size(MissingVotes) =:= 0;
do_have_quorum(AllVotes, {majority, QuorumNodes}) ->
    Votes = sets:intersection(AllVotes, QuorumNodes),
    sets:size(Votes) * 2 > sets:size(QuorumNodes).

is_quorum_feasible(Peers, FailedVotes, Quorum) ->
    PossibleVotes = Peers -- FailedVotes,
    have_quorum(PossibleVotes, Quorum).

-ifdef(HAVE_SYNC_DIR).

sync_dir(Path) ->
    case file:open(Path, [directory, raw]) of
        {ok, Fd} ->
            file:sync(Fd);
        {error, _} = Error ->
            Error
    end.

-else.                                          % -ifdef(HAVE_SYNC_DIR)

sync_dir(_Path) ->
    ok.

-endif.

atomic_write_file(Path, Body) ->
    TmpPath = Path ++ ".tmp",
    case file:open(TmpPath, [write, raw]) of
        {ok, File} ->
            try Body(File) of
                ok ->
                    atomic_write_file_commit(File, Path, TmpPath);
                Error ->
                    atomic_write_file_cleanup(File, TmpPath),
                    Error
            catch
                T:E:Stack ->
                    atomic_write_file_cleanup(File, TmpPath),
                    erlang:raise(T, E, Stack)
            end;
        Error ->
            Error
    end.

atomic_write_file_cleanup(File, TmpPath) ->
    ok = file:close(File),
    ok = file:delete(TmpPath).

atomic_write_file_commit(File, Path, TmpPath) ->
    Dir = filename:dirname(Path),
    ok = file:sync(File),
    ok = file:close(File),
    ok = file:rename(TmpPath, Path),
    ok = sync_dir(Dir).

create_marker(Path) ->
    create_marker(Path, <<>>).

create_marker(Path, Content) ->
    atomic_write_file(Path,
                      fun (File) ->
                              file:write(File, Content)
                      end).

delete_marker(Path) ->
    Dir = filename:dirname(Path),
    case file:delete(Path) of
        ok ->
            sync_dir(Dir);
        {error, enoent} ->
            sync_dir(Dir);
        {error, _} = Error ->
            Error
    end.

mkdir_p(Path) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case check_file_exists(Path, directory) of
                ok ->
                    ok;
                {error, enoent} ->
                    file:make_dir(Path);
                {error, {wrong_file_type, _, _}} ->
                    {error, eexist};
                {error, _} = Error ->
                    Error
            end;
        Error ->
            Error
    end.

check_file_exists(Path, Type) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            ActualType = Info#file_info.type,
            case ActualType =:= Type of
                true ->
                    ok;
                false ->
                    {error, {wrong_file_type, Type, ActualType}}
            end;
        Error ->
            Error
    end.

delete_recursive(Path) ->
    case file:del_dir_r(Path) of
        ok ->
            ok;
        {error, enoent} ->
            ok;
        Error ->
            Error
    end.

read_full(Fd, Size) ->
    case file:read(Fd, Size) of
        {ok, Data} when byte_size(Data) < Size ->
            eof;
        Other ->
            Other
    end.

queue_foreach(Fun, Queue) ->
    case queue:out(Queue) of
        {empty, _} ->
            ok;
        {{value, Value}, NewQueue} ->
            Fun(Value),
            queue_foreach(Fun, NewQueue)
    end.

-ifdef(TEST).
queue_foreach_test() ->
    Q = queue:from_list([1,2,3,4,5]),
    queue_foreach(
      fun (Elem) ->
              self() ! Elem
      end, Q),

    Rcv = fun () ->
                  receive
                      Msg -> Msg
                  after
                      0 ->
                          exit(no_msg)
                  end
          end,

    ?assertEqual(1, Rcv()),
    ?assertEqual(2, Rcv()),
    ?assertEqual(3, Rcv()),
    ?assertEqual(4, Rcv()),
    ?assertEqual(5, Rcv()).
-endif.

queue_takefold(Fun, Acc, Queue) ->
    case queue:out(Queue) of
        {empty, _} ->
            {Acc, Queue};
        {{value, Value}, NewQueue} ->
            case Fun(Value, Acc) of
                {true, NewAcc} ->
                    queue_takefold(Fun, NewAcc, NewQueue);
                false ->
                    {Acc, Queue}
            end
    end.

-ifdef(TEST).
queue_takefold_test() ->
    Q = queue:from_list(lists:seq(1, 10)),
    MkFun = fun (CutOff) ->
                    fun (V, Acc) ->
                            case V =< CutOff of
                                true ->
                                    {true, Acc+V};
                                false ->
                                    false
                            end
                    end
            end,

    Test = fun (ExpectedSum, ExpectedTail, CutOff) ->
                   {Sum, NewQ} = queue_takefold(MkFun(CutOff), 0, Q),
                   ?assertEqual(ExpectedSum, Sum),
                   ?assertEqual(ExpectedTail, queue:to_list(NewQ))
           end,

    Test(0, lists:seq(1,10), 0),
    Test(15, lists:seq(6,10), 5),
    Test(55, [], 42).
-endif.

queue_takewhile(Pred, Queue) ->
    {Result, _} =
        queue_takefold(
          fun (Value, Acc) ->
                  case Pred(Value) of
                      true ->
                          {true, queue:in(Value, Acc)};
                      false ->
                          false
                  end
          end, queue:new(), Queue),
    Result.

-ifdef(TEST).
queue_takewhile_test() ->
    Q = queue:from_list(lists:seq(1, 10)),
    ?assertEqual(lists:seq(1, 5),
                 queue:to_list(queue_takewhile(
                                 fun (V) ->
                                         V =< 5
                                 end, Q))).
-endif.

queue_dropwhile(Pred, Queue) ->
    {_, NewQueue} =
        queue_takefold(
          fun (Value, _) ->
                  case Pred(Value) of
                      true ->
                          {true, unused};
                      false ->
                          false
                  end
          end, unused, Queue),
    NewQueue.

-ifdef(TEST).
queue_dropwhile_test() ->
    Q = queue:from_list(lists:seq(1, 10)),
    Test = fun (Expected, CutOff) ->
                   NewQ = queue_dropwhile(fun (V) -> V =< CutOff end, Q),
                   ?assertEqual(Expected, queue:to_list(NewQ))
           end,
    Test(lists:seq(1,10), 0),
    Test(lists:seq(6,10), 5),
    Test([], 42).
-endif.

log_entry_revision(#log_entry{history_id = HistoryId, seqno = Seqno}) ->
    {HistoryId, Seqno}.

sanitize_entry(#log_entry{value = Value} = LogEntry) ->
    SanitizedValue =
        case Value of
            #rsm_command{payload = {command, _}} = Command ->
                Command#rsm_command{payload = {command, '...'}};
            _ ->
                Value
        end,

    LogEntry#log_entry{value = SanitizedValue}.

sanitize_entries(Entries) ->
    sanitize_entries(Entries, 5).

sanitize_entries([], _) ->
    [];
sanitize_entries(_, 0) ->
    ['...'];
sanitize_entries([Entry | Entries], MaxEntries) ->
    [sanitize_entry(Entry) | sanitize_entries(Entries, MaxEntries - 1)].

sanitize_stacktrace([{Mod, Fun, [_|_] = Args, Info} | Rest]) ->
    [{Mod, Fun, length(Args), Info} | Rest];
sanitize_stacktrace(Stacktrace) ->
    Stacktrace.

sanitize_reason({Reason, Stack} = Pair) ->
    Sanitize =
        %% https://www.erlang.org/doc/reference_manual/errors.html#exit-reasons
        case Reason of
            {badmatch, _} ->
                true;
            {case_clause, _} ->
                true;
            {try_clause, _} ->
                true;
            {bad_fun, _} ->
                true;
            {bad_arity, _} ->
                true;
            {nocatch, _} ->
                true;
            _ when Reason =:= badarg;
                   Reason =:= badarith;
                   Reason =:= function_clause;
                   Reason =:= if_clause;
                   Reason =:= undef;
                   Reason =:= timeout_value;
                   Reason =:= noproc;
                   Reason =:= noconnection;
                   Reason =:= system_limit ->
                true;
            _ ->
                false
        end,

    case Sanitize of
        true ->
            {Reason, sanitize_stacktrace(Stack)};
        false ->
            Pair
    end;
sanitize_reason(Reason) ->
    Reason.

shuffle(List) when is_list(List) ->
    [N || {_R, N} <- lists:keysort(1, [{rand:uniform(), X} || X <- List])].

announce_important_change(Type) ->
    gen_event:notify(?EXTERNAL_EVENTS_SERVER, {important_change, Type}).

is_function_exported(Mod, Fun, Arity) ->
    case code:ensure_loaded(Mod) of
        {module, _} ->
            erlang:function_exported(Mod, Fun, Arity);
        _ ->
            false
    end.

read_int_from_file(Path, Default) ->
    case file:read_file(Path) of
        {ok, Contents} ->
            binary_to_integer(string:trim(Contents));
        {error, enoent} ->
            Default;
        {error, Error} ->
            exit({read_failed, Path, Error})
    end.

store_int_to_file(Path, Value) ->
    atomic_write_file(
      Path,
      fun (Fd) ->
              file:write(Fd, [integer_to_binary(Value), $\n])
      end).
