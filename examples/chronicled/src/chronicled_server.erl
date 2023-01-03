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
-module(chronicled_server).

-include_lib("kernel/include/logger.hrl").

-export([start/0, stop/0]).
-export([init/2, content_types_provided/2, json_api/2,
         content_types_accepted/2, allowed_methods/2,
         allow_missing_post/2, delete_resource/2]).

-record(state, {domain, op}).

start() ->
    Port = get_port(),
    Opts = get_options(),

    ?LOG_DEBUG("starting cowboy rest server: ~p", [Port]),
    ?LOG_DEBUG("cookie: ~p", [erlang:get_cookie()]),
    ?LOG_DEBUG("node: ~p, nodes: ~p", [node(), nodes()]),

    {ok, _} = cowboy:start_clear(http, [{port, Port}], Opts),
    ignore.

stop() ->
    ok = cowboy:stop_listener(http).

get_port() ->
    8080 + application:get_env(chronicled, instance, 0).

get_options() ->
    Dispatch =
        cowboy_router:compile(
          [
           {'_', [
                  {"/config/info", ?MODULE, #state{domain=config,
                                                   op=info}},
                  {"/config/addnode", ?MODULE, #state{domain=config,
                                                      op={addnode, voter}}},
                  {"/config/addvoter", ?MODULE, #state{domain=config,
                                                       op={addnode, voter}}},
                  {"/config/addreplica", ?MODULE,
                   #state{domain=config, op={addnode, replica}}},
                  {"/config/removenode", ?MODULE, #state{domain=config,
                                                         op=removenode}},
                  {"/config/provision", ?MODULE, #state{domain=config,
                                                        op=provision}},
                  {"/config/failover", ?MODULE, #state{domain=config,
                                                       op=failover}},
                  {"/node/wipe", ?MODULE, #state{domain=node, op=wipe}},
                  {"/node/status", ?MODULE, #state{domain=node, op=status}},
                  {"/cluster/peers", ?MODULE, #state{domain=cluster, op=peers}},
                  {"/cluster/status", ?MODULE,
                   #state{domain=cluster, op=status}},
                  {"/kv", ?MODULE, #state{domain=kv, op=txn}},
                  {"/kv/:key", ?MODULE, #state{domain=kv}}
                 ]}
          ]),
    #{env => #{dispatch => Dispatch}}.

init(Req, State) ->
    case State of
        #state{domain=kv, op=undefined} ->
            Method = method_to_atom(cowboy_req:method(Req)),
            ?LOG_DEBUG("Method: ~p", [Method]),
            {cowboy_rest, Req, State#state{op = Method}};
        #state{domain=kv} ->
            {cowboy_rest, Req, State};
        #state{domain=config} ->
            {ok, config_api(Req, State), State};
        #state{domain=node} ->
            {ok, node_api(Req, State), State};
        #state{domain=cluster} ->
            {ok, cluster_api(Req, State), State}
    end.

allowed_methods(Req, State) ->
    Methods = [<<"GET">>, <<"PUT">>, <<"POST">>, <<"DELETE">>],
    {Methods, Req, State}.

content_types_provided(Req, State) ->
    {[
      {<<"application/json">>, json_api}
     ], Req, State}.

content_types_accepted(Req, State) ->
    {[
      {<<"application/json">>, json_api}
     ], Req, State}.

delete_resource(Req, State) ->
    Key = cowboy_req:binding(key, Req),
    ?LOG_DEBUG("delete_resource called for key: ~p", [Key]),
    case delete_value(Req, any) of
        true ->
            {true, Req, State};
        no_rsm ->
            {stop, reply(400, <<"no rsm">>, Req), State}
    end.

allow_missing_post(Req, State) ->
    {false, Req, State}.

json_api(Req, #state{domain=kv, op=get}=State) ->
    case get_value(Req) of
        {ok, {Val, {HistoryId, Seqno} = Rev}} ->
            ?LOG_DEBUG("Rev: ~p", [Rev]),
            R = {[{<<"rev">>,
                   {[{<<"history_id">>, HistoryId},
                     {<<"seqno">>, Seqno}]}
                  },
                  {<<"value">>, jiffy:decode(Val)}]},
            {jiffy:encode(R), Req, State};
        not_found ->
            {stop, reply(404, <<>>, Req), State};
        no_rsm ->
            {stop, reply(400, <<"no rsm">>, Req), State}
    end;
json_api(Req, #state{domain=kv, op=post}=State) ->
    {Result, Req1} = set_value(Req, any),
    {Result, Req1, State};
json_api(Req, #state{domain=kv, op=put}=State) ->
    {Result, Req1} = set_value(Req, any),
    {Result, Req1, State};
json_api(Req, #state{domain=kv, op=txn}=State) ->
    {Result, Req1} = txn(Req),
    {Result, Req1, State}.

config_api(Req, #state{domain=config, op=info}) ->
    Peers = chronicle:get_peers(),
    reply_json(200, Peers, Req);
config_api(Req, #state{domain=config, op={addnode, Type}}) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("read content: ~p", [Body]),
    {Result, Message} = case parse_nodes(Body) of
                            Nodes when is_list(Nodes) ->
                                add_nodes(Nodes, Type);
                            {error, Msg} ->
                                {false, Msg}
                        end,
    Status = case Result of true -> 200; _ -> 400 end,
    reply_json(Status, Message, Req1);
config_api(Req, #state{domain=config, op=removenode}) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("read content: ~p", [Body]),
    {Result, Message} = case parse_nodes(Body) of
                            Nodes when is_list(Nodes) ->
                                remove_nodes(Nodes);
                            {error, Msg} ->
                                {false, Msg}
                        end,
    Status = case Result of true -> 200; _ -> 400 end,
    reply_json(Status, Message, Req1);
config_api(Req, #state{domain=config, op=provision}) ->
    Machines = [{kv, chronicle_kv, []}],
    case chronicle:provision(Machines) of
        ok ->
            ok;
        {error, provisioned} ->
            ok
    end,
    reply_json(200, <<"provisioned">>, Req);
config_api(Req, #state{domain=config, op=failover}) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    {Result, Message} = case parse_nodes(Body) of
                            KeepNodes when is_list(KeepNodes) ->
                                case chronicle:failover(KeepNodes) of
                                    ok ->
                                        {true, <<"ok">>};
                                    {error, Error} ->
                                        {false,
                                         iolist_to_binary(
                                           io_lib:format("~w", [Error]))}
                                end;
                            {error, Msg} ->
                                {false, Msg}
                        end,
    Status = case Result of true -> 200; _ -> 400 end,
    reply_json(Status, Message, Req1).

node_api(Req, #state{domain=node, op=wipe}) ->
    ok = chronicle:wipe(),
    reply_json(200, <<"ok">>, Req);
node_api(Req, #state{domain=node, op=status}) ->
    Status = #{leader => get_leader_info()},
    reply_json(200, Status, Req).

cluster_api(Req, #state{domain=cluster, op=peers}) ->
    reply_json(200, chronicle:get_peer_statuses(), Req);
cluster_api(Req, #state{domain=cluster, op=status}) ->
    reply_json(200, chronicle:get_cluster_status(), Req).

%% internal module functions
reply_json(Status, Response, Req) ->
    reply(Status, jiffy:encode(Response), Req).

reply(Status, Response, Req) ->
    cowboy_req:reply(Status,
                     #{<<"content-type">> => <<"application/json">>},
                     Response, Req).

method_to_atom(<<"GET">>) ->
    get;
method_to_atom(<<"PUT">>) ->
    put;
method_to_atom(<<"POST">>) ->
    post;
method_to_atom(<<"DELETE">>) ->
    delete.

get_value(Req) ->
    case cowboy_req:binding(key, Req) of
        undefined ->
            not_found;
        BinKey ->
            Key = binary_to_list(BinKey),
            Consistency = get_consistency(Req),
            do_get_value(Key, Consistency)
    end.

get_consistency(Req) ->
    #{consistency := Consistency} =
        cowboy_req:match_qs(
          [{consistency, [fun consistency_constraint/2], local}],
          Req),
    Consistency.

consistency_constraint(forward, Value) ->
    case Value of
        <<"local">> ->
            {ok, local};
        <<"quorum">> ->
            {ok, quorum};
        _ ->
            {error, bad_consistency}
    end;
consistency_constraint(format_error, _Error) ->
    "consistency must be one of 'local' or 'quorum'".

do_get_value(Key, Consistency) ->
    ?LOG_DEBUG("key: ~p", [Key]),
    try chronicle_kv:get(kv, Key, #{read_consistency => Consistency}) of
        {ok, Value} ->
            {ok, Value};
        _ ->
            not_found
    catch
        exit:{noproc, _} ->
            no_rsm;
        error:badarg ->
            no_rsm
    end.

set_value(Req, ExpectedRevision) ->
    BinKey = cowboy_req:binding(key, Req),
    Key = binary_to_list(BinKey),
    ?LOG_DEBUG("key: ~p", [Key]),
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("read content: ~p", [Body]),
    try jiffy:decode(Body) of
        _ ->
            try chronicle_kv:set(kv, Key, Body, ExpectedRevision) of
                {ok, _} ->
                    {true, Req1}
            catch
                exit:{noproc, _} ->
                    {false, Req1}
            end
    catch _:_ ->
            ?LOG_DEBUG("body not json: ~p", [Body]),
            {false, Req1}
    end.

delete_value(Req, ExpectedRevision) ->
    BinKey = cowboy_req:binding(key, Req),
    Key = binary_to_list(BinKey),
    ?LOG_DEBUG("deleting key: ~p", [Key]),
    try chronicle_kv:delete(kv, Key, ExpectedRevision) of
        {ok, _} ->
            true
    catch
        exit:{noproc, _} ->
            no_rsm
    end.

get_retries(Req) ->
    #{retries := Retries} =
        cowboy_req:match_qs(
          [{retries, [fun retries_constraint/2], 50}],
          Req),
    Retries.

retries_constraint(forward, Value) ->
    try binary_to_integer(Value) of
        Retries when Retries > 0 ->
            {ok, Retries};
        _ ->
            {error, bad_retries}
    catch
        error:badarg ->
            {error, bad_retries}
    end;
retries_constraint(format_error, _Error) ->
    "retries must be a positive integer".

txn(Req) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    case parse_txn(Body) of
        error ->
            {false, Req1};
        Ops ->
            Retries = get_retries(Req1),
            Consistency = get_consistency(Req1),
            try do_txn(Retries, Consistency, Ops) of
                {ok, Snapshot} ->
                    {stop, reply_json(200, txn_reply(Snapshot), Req1)};
                {error, exceeded_retries} ->
                    {stop, reply(409, "Transaction exceeded retries", Req1)}
            catch
                exit:{noproc, _} ->
                    {false, Req1}
            end
    end.

txn_reply(Snapshot) ->
    {lists:map(
       fun ({Key, {Value, {HistoryId, Seqno}}}) ->
               {list_to_binary(Key),
                {[{value, jiffy:decode(Value)},
                  {rev, {[{history_id, HistoryId}, {seqno, Seqno}]}}]}}
       end, maps:to_list(Snapshot))}.

do_txn(Retries, Consistency, Ops) ->
    Gets = [Key || {get, Key} <- Ops],
    Sets = [Op || {set, _Key, _Value} = Op <- Ops],
    Result = chronicle_kv:txn(
               kv,
               fun (Txn) ->
                       Snapshot = chronicle_kv:txn_get_many(Gets, Txn),
                       case Sets of
                           [] ->
                               {abort, {ok, Snapshot}};
                           _ ->
                               {commit, Sets, Snapshot}
                       end
               end, #{retries => Retries,
                      read_consistency => Consistency}),

    case Result of
        {ok, _Revision, Snapshot} ->
            {ok, Snapshot};
        _ ->
            Result
    end.

parse_txn(Body) ->
    try jiffy:decode(Body, [return_maps]) of
        Ops when is_list(Ops) ->
            try
                parse_txn_ops(Ops)
            catch
                error:badarg ->
                    error
            end;
        _ ->
            error
    catch _:_ ->
            error
    end.

parse_txn_ops([]) ->
    [];
parse_txn_ops([Op | Ops]) ->
    case Op of
        #{<<"op">> := <<"set">>,
          <<"key">> := Key,
          <<"value">> := Value} ->
            [{set,
              binary_to_list(Key),
              jiffy:encode(Value)} | parse_txn_ops(Ops)];
        #{<<"op">> := <<"get">>, <<"key">> := Key} ->
            [{get, binary_to_list(Key)} | parse_txn_ops(Ops)]
    end.

parse_nodes(Body) ->
    try jiffy:decode(Body) of
        Nodes when is_list(Nodes) ->
            [binary_to_atom(N, utf8) || N <- Nodes];
        Node when is_binary(Node) ->
            [binary_to_atom(Node, utf8)];
        _ ->
            {error, "invalid JSON list of nodes"}
    catch _:_ ->
            {error, "body not json"}
    end.

add_nodes(Nodes, Type) ->
    CurrentNodes = get_nodes_of_type(Type),
    ToAdd = [N || N <- Nodes, not(lists:member(N, CurrentNodes))],
    case ToAdd of
        [] ->
            {false, <<"nodes already added">>};
        _ ->
            case call_nodes(ToAdd, prepare_join) of
                true ->
                    ?LOG_DEBUG("nodes ~p", [nodes()]),
                    ok = do_add_nodes(ToAdd, Type),
                    case call_nodes(ToAdd, join_cluster) of
                        true ->
                            {true, <<"nodes added">>};
                        false ->
                            {false, <<"join_cluster failed">>}
                    end;
                false ->
                    {false, <<"prepare_join failed">>}
            end
    end.

call_nodes(Nodes, Call) ->
    ClusterInfo = chronicle:get_cluster_info(),
    {Results, BadNodes} = rpc:multicall(Nodes,
                                        chronicle, Call, [ClusterInfo]),
    BadResults =
        [{N, R} || {N, R} <- Results, R =/= ok] ++
        [{N, down} || N <- BadNodes],

    case BadResults of
        [] ->
            true;
        _ ->
            ?LOG_DEBUG("~p failed on some nodes:~n~p", [Call, BadResults]),
            false
    end.

remove_nodes(Nodes) ->
    PresentNodes = get_present_nodes(),
    ToRemove = [N || N <- Nodes, lists:member(N, PresentNodes)],
    case ToRemove of
        Nodes ->
            Result = chronicle:remove_peers(Nodes),
            ?LOG_DEBUG("Result of voter addition: ~p", [Result]),
            case Result of
                ok ->
                    {true, <<"nodes removed">>};
                _ ->
                    {false, <<"nodes could not be removed">>}
            end;
        _ ->
            {false, <<"some nodes not part of cluster">>}
    end.

get_present_nodes() ->
    #{voters := Voters, replicas := Replicas} = chronicle:get_peers(),
    Voters ++ Replicas.

get_nodes_of_type(Type) ->
    case Type of
        voter ->
            chronicle:get_voters();
        replica ->
            chronicle:get_replicas()
    end.

do_add_nodes(Nodes, Type) ->
    case Type of
        voter ->
            chronicle:add_voters(Nodes);
        replica ->
            chronicle:add_replicas(Nodes)
    end.

get_leader_info() ->
    case chronicle_leader:get_leader() of
        {Leader, {HistoryId, {Term, _}}} ->
            #{node => Leader,
              history_id => HistoryId,
              term => Term};
        no_leader ->
            null
    end.
