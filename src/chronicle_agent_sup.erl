%% @author Couchbase <info@couchbase.com>
%% @copyright 2021 Couchbase, Inc.
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
-module(chronicle_agent_sup).

-behavior(supervisor).

-include("chronicle.hrl").

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link(?START_NAME(?MODULE), ?MODULE, []).

%% callbacks
init([]) ->
    Flags = #{strategy => one_for_all,
              %% Make sure that everything following chronicle_agent_sup in
              %% the top-level supervisor restarts if any of the processes
              %% here crash.
              intensity => 0,
              period => 10},
    {ok, {Flags, child_specs()}}.

child_specs() ->
    SnapshotMgr = #{id => chronicle_snapshot_mgr,
                    start => {chronicle_snapshot_mgr, start_link, []},
                    restart => permanent,
                    shutdown => brutal_kill,
                    type => worker},

    RSMEvents = #{id => ?RSM_EVENTS,
                  start => {chronicle_events, start_link, [?RSM_EVENTS]},
                  restart => permanent,
                  shutdown => 1000,
                  type => worker},

    Agent = #{id => chronicle_agent,
              start => {chronicle_agent, start_link, []},
              restart => permanent,
              shutdown => 5000,
              type => worker},

    [SnapshotMgr, RSMEvents, Agent].
