-module(flu_session_tests).
-author('Max Lapshin <max@maxidoors.ru>').
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("../src/flu_session.hrl").
-compile(export_all).



setup_flu_session() ->
  Apps = [crypto, ranch, gen_tracker, cowboy, flussonic, inets],
  [application:start(App) || App <- Apps],
  % cowboy:stop_listener(fake_http),
  gen_tracker_sup:start_tracker(flu_files),
  gen_tracker_sup:start_tracker(flu_streams),


  Modules = [flu_session],
  meck:new(Modules, [{passthrough,true}]),
  Table = ets:new(test_sessions, [{keypos,2},public]),
  meck:expect(flu_session,table, fun() -> Table end),
  meck:expect(flu_session, timeout, fun() -> 100 end),
  
  ServerConf = [
    {file, "vod", "../../../priv", [{sessions, "http://127.0.0.1:6070/vodauth"}]},
    {rewrite, "cam2", "passive://localhost/", [{sessions, "http://127.0.0.1:6070/streamauth"}]},
    {live, "live", [{sessions, "http://127.0.0.1:6070/liveauth"}]}
  ],
  {ok, ServerConfig} = flu_config:parse_config(ServerConf, undefined),
  {ok, _} = cowboy:start_http(our_http, 1, [{port, 5555}],
    [{dispatch, [{'_', flu_config:parse_routes(ServerConfig)}]}]
  ),
  {Modules}.

teardown_flu_session({Modules}) ->
  error_logger:delete_report_handler(error_logger_tty_h),
  ets:delete(flu_session:table()),
  % cowboy:stop_listener(fake_http),
  application:stop(cowboy),
  application:stop(flussonic),
  application:stop(gen_tracker),
  application:stop(ranch),
  application:stop(inets),
  meck:unload(Modules),
  error_logger:add_report_handler(error_logger_tty_h),
  ok.  


flu_session_test_() ->
  TestFunctions = [{atom_to_list(F), fun ?MODULE:F/0} || {F,0} <- ?MODULE:module_info(exports),
    lists:prefix("test_", atom_to_list(F))],
  {foreach, 
    fun setup_flu_session/0,
    fun teardown_flu_session/1,
    TestFunctions
  }.

http_mock_url() -> "http://127.0.0.1:6070/auth".



test_new_session1() ->
  Session = flu_session:new_or_update([{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [{access,granted}]),
  ?assertEqual(granted, flu_session:update_session(Session)),
  ?assertEqual(<<"cam0">>, flu_session:url(Session)).


test_new_session2() ->
  Session = flu_session:new_or_update([{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [{access,granted},{name,<<"cam1">>}]),
  ?assertEqual(granted, flu_session:update_session(Session)),
  ?assertEqual(<<"cam1">>, flu_session:url(Session)).




test_remember_positive_with_changing_reply() ->
  meck:expect(flu_session, backend_request, fun(_,_,_) -> {ok, [{access,granted}]} end),
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [])),

  meck:expect(flu_session, backend_request, fun(_,_,_) -> {error, {403,"denied"}, []} end),
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [])).



test_cached_positive() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(_,_,_) ->
    Self ! backend_request,
    {ok, [{access,granted},{user_id,15},{auth_time, 10000}]}
  end),
  Identity = [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}],
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [])),
  assertBackendRequested(backend_wasnt_requested),

  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [])),

  receive
    backend_request -> error(backend_was_requested_twice)
  after
    100 -> ok
  end,

  ok.



test_remember_negative() ->
  meck:expect(flu_session, backend_request, fun(_,_,_) -> {error, {403,"denied"}, []} end),
  ?assertMatch({error, 403, _},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [])),

  meck:expect(flu_session, backend_request, fun(_,_,_) -> {ok, [{access,granted}]} end),
  ?assertMatch({error, 403, _},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [])),
  ok.


test_monitor_session() ->
  meck:expect(flu_session, backend_request, fun(_,_,_) -> {ok, [{access,granted}]} end),
  Identity = [{ip,<<"127.0.0.5">>},{token,<<"123">>},{name,<<"cam0">>}],

  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [{type,<<"rtmp">>},{pid,self()}])),
  ?assertMatch([_], flu_session:list()),
  [Info] = flu_session:list(),
  ?assertEqual(<<"127.0.0.5">>, proplists:get_value(ip, Info)),
  Session = flu_session:find_session(Identity),
  flu_session ! {'DOWN', flu_session:ref(Session), undefined, self(), undefined},
  gen_server:call(flu_session, sync_call),
  ?assertEqual([], flu_session:list()),

  gen_server:call(flu_session, {unregister, flu_session:ref(Session)}),
  ok.


test_backend_down() ->
  ?assertMatch({error,403,_}, flu_session:verify("http://127.0.0.5/", [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [])).

test_session_info() ->
  meck:expect(flu_session, backend_request, fun(_,_,_) -> {ok, [{access,granted},{user_id,15}]} end),
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}], [])),
  Info = flu_session:info([{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}]),
  ?assertEqual(<<"cam0">>, proplists:get_value(name, Info)),
  ?assertEqual(15, proplists:get_value(user_id, Info)),
  ?assertEqual(granted, proplists:get_value(access, Info)),
  ok.


assertBackendRequested(Msg) ->
  receive
    backend_request -> ok
  after
    100 -> error(Msg)
  end.



test_backend_arguments_on_file() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(URL, Identity, Options) ->
    Self ! {backend_request, {URL, Identity, Options}},
    {ok, [{access,denied}]}
  end),
  {ok, Reply} = httpc:request(get, 
    {"http://127.0.0.1:5555/vod/bunny.mp4/manifest.f4m?token=123", [
    {"Referer", "http://ya.ru/"}, {"X-Forwarded-For", "94.95.96.97"}]},[],[]),
  ?assertMatch({{_,403,_}, _, _}, Reply),

  {URL, Identity, Options} = receive
    {backend_request, QsVals} -> QsVals
  after
    10 -> error(backend_wasnt_requested)
  end,

  ?assertEqual(<<"http://127.0.0.1:6070/vodauth">>, URL),
  ?assertEqual(<<"123">>, proplists:get_value(token, Identity)),
  ?assertEqual(<<"vod/bunny.mp4">>, proplists:get_value(name, Identity)),
  ?assertEqual(<<"94.95.96.97">>, proplists:get_value(ip, Identity)),
  ?assertEqual(<<"http://ya.ru/">>, proplists:get_value(referer, Options)),

  ok.



test_backend_arguments_on_stream() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(URL, Identity, Options) ->
    Self ! {backend_request, {URL, Identity, Options}},
    {ok, [{access,denied}]}
  end),
  {ok, Reply} = httpc:request(get, 
    {"http://127.0.0.1:5555/cam2/manifest.f4m?token=123", [
    {"Referer", "http://ya.ru/"}, {"X-Forwarded-For", "94.95.96.97"}]},[],[]),
  ?assertMatch({{_,403,_}, _, _}, Reply),

  {URL, Identity, Options} = receive
    {backend_request, QsVals} -> QsVals
  after
    10 -> error(backend_wasnt_requested)
  end,

  ?assertEqual(<<"http://127.0.0.1:6070/streamauth">>, URL),
  ?assertEqual(<<"123">>, proplists:get_value(token, Identity)),
  ?assertEqual(<<"cam2">>, proplists:get_value(name, Identity)),
  ?assertEqual(<<"94.95.96.97">>, proplists:get_value(ip, Identity)),
  ?assertEqual(<<"http://ya.ru/">>, proplists:get_value(referer, Options)),

  ok.



test_backend_arguments_on_live() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(URL, Identity, Options) ->
    Self ! {backend_request, {URL, Identity, Options}},
    {ok, [{access,denied}]}
  end),
  {ok, Reply} = httpc:request(get, 
    {"http://127.0.0.1:5555/live/ustream/manifest.f4m?token=123", [
    {"Referer", "http://ya.ru/"}, {"X-Forwarded-For", "94.95.96.97"}]},[],[]),
  ?assertMatch({{_,403,_}, _, _}, Reply),

  {URL, Identity, Options} = receive
    {backend_request, QsVals} -> QsVals
  after
    10 -> error(backend_wasnt_requested)
  end,

  ?assertEqual(<<"http://127.0.0.1:6070/liveauth">>, URL),
  ?assertEqual(<<"123">>, proplists:get_value(token, Identity)),
  ?assertEqual(<<"live/ustream">>, proplists:get_value(name, Identity)),
  ?assertEqual(<<"94.95.96.97">>, proplists:get_value(ip, Identity)),
  ?assertEqual(<<"http://ya.ru/">>, proplists:get_value(referer, Options)),

  ok.



test_backend_is_working_without_options() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(URL, Identity, Options) ->
    Self ! {backend_request, {URL, Identity, Options}},
    {ok, [{access,granted}]}
  end),
  {ok, Reply} = httpc:request(get, 
    {"http://127.0.0.1:5555/vod/bunny.mp4/manifest.f4m?token=123", [
    {"X-Forwarded-For", "94.95.96.97"}]},[],[]),
  ?assertMatch({{_,200,_}, _, _}, Reply),

  {_URL, Identity, Options} = receive
    {backend_request, QsVals} -> QsVals
  after
    10 -> error(backend_wasnt_requested)
  end,
  ?assertEqual(<<"123">>, proplists:get_value(token, Identity)),
  ?assertEqual(<<"vod/bunny.mp4">>, proplists:get_value(name, Identity)),
  ?assertEqual(<<"94.95.96.97">>, proplists:get_value(ip, Identity)),
  ?assertEqual(false, lists:keyfind(referer, 1, Options)),
  ok.


test_expire_and_delete_session() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(_, _, _) ->
    Self ! backend_request,
    {ok,[{access,granted},{user_id,15},{auth_time, 5000}]} 
  end),
  Identity = [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}],
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [])),
  assertBackendRequested(backend_wasnt_requested),

  [#session{session_id = Id}] = ets:tab2list(flu_session:table()),
  ets:update_element(flu_session:table(), Id, [{#session.last_access_time, 0}]),
  flu_session ! clean,
  gen_server:call(flu_session, sync_call),

  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [])),

  assertBackendRequested(backend_wasnt_requested_second_time),
  ok.


test_dont_expire_monitored_session() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(_, _, _) ->
    Self ! backend_request,
    {ok,[{access,granted},{user_id,15},{auth_time, 5000}]} 
  end),
  Identity = [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}],
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [{type,<<"rtmp">>},{pid,self()}])),
  assertBackendRequested(backend_wasnt_requested),
  [#session{session_id = Id}] = ets:tab2list(flu_session:table()),
  ets:update_element(flu_session:table(), Id, [{#session.last_access_time, 0}]),

  flu_session ! clean,
  gen_server:call(flu_session, sync_call),

  ?assertMatch([_], ets:tab2list(flu_session:table())),

  ok.




test_rerequest_expiring_session() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(_, _, _) ->
    Self ! backend_request,
    {ok,[{access,granted},{user_id,15},{auth_time, 5000}]} 
  end),
  Identity = [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}],
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [])),
  assertBackendRequested(backend_wasnt_requested),
  Now = flu:now_ms(),
  #session{} = Session = flu_session:find_session(Identity),
  Session1 = Session#session{last_access_time = Now - 6000}, % a bit more than auth duration
  ets:insert(flu_session:table(), Session1),

  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), Identity, [])),

  assertBackendRequested(backend_wasnt_requested_second_time),
  ok.


test_session_is_not_destroyed_after_rerequest() ->
  Self = self(),
  meck:expect(flu_session, backend_request, fun(_, _, _) ->
    Self ! backend_request,
    {ok,[{access,granted},{user_id,15},{auth_time, 5000}]} 
  end),
  Identity = [{ip,<<"127.0.0.1">>},{token,<<"123">>},{name,<<"cam0">>}],
  ?assertEqual({ok, <<"cam0">>}, flu_session:verify(http_mock_url(), Identity, [])),
  assertBackendRequested(backend_wasnt_requested),

  #session{} = Session = flu_session:find_session(Identity),
  Session1 = Session#session{last_access_time = flu:now_ms() - 6000, bytes_sent = 5254}, % a bit more than auth duration
  ets:insert(flu_session:table(), Session1),

  ?assertEqual({ok, <<"cam0">>}, flu_session:verify(http_mock_url(), Identity, [])),
  assertBackendRequested(backend_wasnt_requested_second_time),

  #session{bytes_sent = BytesSent} = flu_session:find_session(Identity),
  ?assertEqual(5254, BytesSent),
  ok.






test_unique_session_with_new_ip() ->
  meck:expect(flu_session, backend_request, fun(_, _, _) ->
    {ok,[{access,granted},{user_id,14},{unique,true}]} 
  end),
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"1">>},{name,<<"cam0">>}], [])),

  ?assertMatch([#session{ip = <<"127.0.0.1">>}], ets:select(flu_session:table(), ets:fun2ms(fun(#session{user_id = 14, access= granted} = E) -> E end))),

  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"94.95.96.97">>},{token,<<"1">>},{name,<<"cam0">>}], [])),

  ?assertMatch([#session{ip = <<"94.95.96.97">>}], ets:select(flu_session:table(), ets:fun2ms(fun(#session{user_id = 14, access= granted} = E) -> E end))),
  ?assertMatch([#session{ip = <<"127.0.0.1">>}], ets:select(flu_session:table(), ets:fun2ms(fun(#session{user_id = 14, access= denied} = E) -> E end))),
  ok.



test_unique_session_with_persistent_connection() ->
  Connection = spawn(fun() ->
    receive
      Msg -> Msg
    end
  end),

  meck:expect(flu_session, backend_request, fun(_, _, _) ->
    {ok,[{access,granted},{user_id,14},{unique,true}]} 
  end),
  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"127.0.0.1">>},{token,<<"1">>},{name,<<"cam0">>}], [{pid,Connection}])),

  ?assertMatch([#session{ip = <<"127.0.0.1">>, pid = Connection}], 
    ets:select(flu_session:table(), ets:fun2ms(fun(#session{user_id = 14, access= granted} = E) -> E end))),

  ?assertEqual({ok, <<"cam0">>},
    flu_session:verify(http_mock_url(), [{ip,<<"94.95.96.97">>},{token,<<"2">>},{name,<<"cam0">>}], [])),

  ?assertEqual(false, erlang:is_process_alive(Connection)),
  ?assertMatch([#session{ip = <<"127.0.0.1">>, pid = Connection}], 
    ets:select(flu_session:table(), ets:fun2ms(fun(#session{user_id = 14, access= denied} = E) -> E end))),

  ok.






params_validation_test_() ->
  [
   ?_assertException(throw, {error, bad_auth_url}, flu_session:verify(undefined, [], []))
  ,?_assertException(throw, {error, bad_identity}, flu_session:verify("http://no_url/", undefined, []))
  ,?_assertException(throw, {error, bad_token}, flu_session:verify("http://no_url/", [{token, undefined}], []))
  ,?_assertException(throw, {error, bad_token}, flu_session:verify("http://no_url/", [{token, 1234}], []))
  ,?_assertException(throw, {error, bad_ip}, flu_session:verify("http://no_url/", [{token, <<"1234">>}], []))
  ,?_assertException(throw, {error, bad_ip}, flu_session:verify("http://no_url/", [{token, <<"1234">>},{ip, lala}], []))
  ,?_assertException(throw, {error, bad_name}, flu_session:verify("http://no_url/", [{token, <<"1234">>},{ip, <<"127.0.0.1">>}], []))
  ,?_assertException(throw, {error, bad_name}, flu_session:verify("http://no_url/", 
      [{token, <<"1234">>},{ip, <<"127.0.0.1">>}, {name, lala}], []))
  ,?_assertException(throw, {error, bad_name}, flu_session:verify("http://no_url/", 
      [{token, <<"1234">>},{ip, <<"127.0.0.1">>}, {name, undefined}], []))

  ,?_assertException(throw, {error, bad_params}, flu_session:verify("http://no_url/", 
      [{token, <<"1234">>},{ip, <<"127.0.0.1">>}, {name, <<"stream">>}], [[{key,value}]]))
  ].







