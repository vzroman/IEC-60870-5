%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_unbalanced_server).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("unbalanced.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(ACKNOWLEDGE_FRAME(Address), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = 0,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-record(data, {
  name,
  root,
  address,
  switch,
  fcb,
  sent_frame,
  connection
}).

-define(CONNECTION_TIMEOUT, 300000). % 1 min
%% +--------------------------------------------------------------+
%% |                       API implementation                     |
%% +--------------------------------------------------------------+

start(Root, Options) ->
  PID = spawn_link(fun() -> init(Root, Options) end),
  receive
    {ready, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("server is down due to an error: ~p", [Reason]),
      throw(Reason)
  end.

stop(PID) ->
  PID ! {stop, self()}.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Root, #{
  address := Address
} = Options) ->
  Switch = iec60870_switch:start(Options),
  iec60870_switch:add_server(Switch, Address),

  Root ! {ready, self()},
  Connection = start_connection(Root),

  loop(#data{
    name = maps:get(port, Options),
    root = Root,
    address = Address,
    switch = Switch,
    connection = Connection,
    fcb = undefined
  }).

start_connection(Root) ->
  case iec60870_server:start_connection(Root, {?MODULE, self()}, self()) of
    {ok, NewConnection} ->
      erlang:monitor(process, NewConnection),
      NewConnection;
    error ->
      exit(server_stm_start_failed)
  end.

loop(#data{
  name = Name,
  root = Root,
  switch = Switch,
  address = Address,
  fcb = FCB,
  sent_frame = SentFrame,
  connection = Connection
} = Data) ->
  receive
    {data, Switch, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      ?LOGWARNING("server w/ link address ~p received unexpected link address: ~p", [Address, ReqAddress]),
      loop(Data);
    {data, Switch, Unexpected = #frame{control_field = #control_field_response{}}} ->
      ?LOGWARNING("server w/ link address ~p received unexpected response frame: ~p", [Address, Unexpected]),
      loop(Data);
    {data, Switch, #frame{control_field = CF, data = UserData}} ->
      case check_fcb(CF, FCB) of
        {ok, NextFCB} ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop(Data1#data{fcb = NextFCB});
        error ->
          ?LOGWARNING("server w/ link address ~p got check fcb error. CF: ~p, FCB: ~p", [Address, CF, FCB]),
          case SentFrame of
            #frame{} -> send_response(Switch, SentFrame);
            _ -> ignore
          end,
          loop(Data)
      end;
    {'DOWN', _, process, Connection, _Error} ->
      ?LOGWARNING("~p server w/ link address ~p is down", [Name, Address]),
      NewConnection = start_connection( Root ),
      loop(Data#data{connection = NewConnection});
    {'DOWN', _, process, Switch, SwitchError} ->
      ?LOGWARNING("~p server w/ link address ~p is down because of the switch error: ~p", [Name, Address, SwitchError]),
      exit( SwitchError );
    {stop, Root} ->
      ?LOGWARNING("server w/ link address ~p has been terminated by the owner", [Address])
%%  TODO: Should we ignore ASDU?
%%  {asdu, _Connection, _Data} when FCB =:= undefined->
%%    loop(Data)
  after
    ?CONNECTION_TIMEOUT->
      drop_queue(),
      loop(Data)
  end.

check_fcb(#control_field_request{fcv = 0, fcb = _ReqFCB}, _FCB) ->
  {ok, 0}; %% TODO. Is it correct to treat fcv = 0 as a reset?
check_fcb(#control_field_request{fcv = 1, fcb = FCB}, FCB) ->
  error;
check_fcb(#control_field_request{fcv = 1, fcb = RecFCB}, _FCB) ->
  {ok, RecFCB}.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  switch = Switch,
  address = Address
} = Data) ->
  ?LOGINFO("DEBUG. Server received RESET REMOTE LINK!"),
  drop_asdu(),
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  switch = Switch,
  address = Address
} = Data) ->
  % TODO. Do we need to do anything? May be restart connection?
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  switch = Switch,
  address = Address
} = Data) ->
  Connection ! {asdu, self(), ASDU},
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
} = Data) ->
  Connection ! {asdu, self(), ASDU},
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  switch = Switch,
  address = Address
} = Data) ->
  Data#data{
    sent_frame = send_response(Switch, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  switch = Switch,
  address = Address
} = Data) ->
  Data#data{
    sent_frame = send_response(Switch, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(RequestData, _UserData, #data{
  switch = Switch,
  address = Address,
  connection = Connection
} = Data)
  when RequestData =:= ?REQUEST_DATA_CLASS_1;
       RequestData =:= ?REQUEST_DATA_CLASS_2 ->
  Response =
    case check_data(Connection) of
      {ok, ConnectionData} ->
        ?LOGINFO("DEBUG. Server request DATA CLASS 2!"),
        #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 0,
            dfc = 0,
            function_code = ?USER_DATA
          },
          data = ConnectionData
        };
      _ ->
        ?LOGINFO("DEBUG. Server request DATA CLASS 2, NO DATA!"),
        %% Data isn't available
        #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 0,
            dfc = 0,
            function_code = ?NACK_DATA_NOT_AVAILABLE
          }
        }
    end,
  Data#data{
    sent_frame = send_response(Switch, Response)
  };

handle_request(InvalidFC, _UserData, #data{address = Address} = Data) ->
  ?LOGERROR("server w/ link address ~p received invalid request function code: ~p", [Address, InvalidFC]),
  Data.

send_response(Switch, Frame) ->
  Switch ! {send, self(), Frame},
  Frame.

check_data(Connection) ->
  receive
    {asdu, Connection, Data} -> {ok, Data}
  after
    0 -> undefined
  end.

drop_asdu() ->
  receive
    {asdu, _Connection, _Data} -> drop_asdu()
  after
    0 -> ok
  end.

drop_queue() ->
  receive
    _Any -> drop_queue()
  after
    0 -> ok
  end.