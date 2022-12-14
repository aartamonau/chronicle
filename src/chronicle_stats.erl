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
-module(chronicle_stats).

-include("chronicle.hrl").

-export([report_histo/4, report_counter/2, report_gauge/2, report_max/4]).
-export([ignore_stats/1]).

report_histo(Metric, Max, Unit, Value) ->
    report({histo, Metric, Max, Unit, Value}).

report_counter(Metric, By) ->
    report({counter, Metric, By}).

report_gauge(Metric, Value) ->
    report({gauge, Metric, Value}).

report_max(Metric, Window, Bucket, Value) ->
    report({max, Metric, Window, Bucket, Value}).

report(Event) ->
    try
        (persistent_term:get(?CHRONICLE_STATS))(Event)
    catch
        T:E ->
            ?ERROR("Failed to report stats ~w: ~w", [Event, {T, E}])
    end.

ignore_stats(_) ->
    ok.
