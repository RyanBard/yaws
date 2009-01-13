%%% File    : yaws_sendfile.erl
%%% Author  : Steve Vinoski <vinoski@ieee.org>
%%% Description : interface to sendfile linked-in driver for Yaws
%%% Created :  9 Nov 2008 by Steve Vinoski <vinoski@ieee.org>

-module(yaws_sendfile).
-export([start_link/0, init/1, stop/0, send/2, send/3, send/4]).

-include_lib("kernel/include/file.hrl").

start_link() ->
    Shlib = "yaws_sendfile_drv",
    Dir = case yaws_generated:is_local_install() of
	      true ->
		  filename:dirname(code:which(?MODULE)) ++ "/../priv/lib";
	       false ->
		  %% ignore dialyzer on this one
		  PrivDir = code:priv_dir(yaws),
		  filename:join(PrivDir,"lib")
	  end,
    case erl_ddll:load_driver(Dir, Shlib) of
        ok -> ok;
        {error, already_loaded} -> ok;
        _ -> exit({error, could_not_load_driver})
    end,
    {ok, spawn_link(?MODULE, init, [Shlib])}.

init(Shlib) ->
    register(?MODULE, self()),
    process_flag(trap_exit, true),
    Port = open_port({spawn, Shlib}, [binary]),
    loop(Port).

stop() ->
    ?MODULE ! stop,
    unregister(?MODULE),
    ok.

send(Out, Filename) ->
    send(Out, Filename, 0, 0).
send(Out, Filename, Offset) ->
    send(Out, Filename, Offset, 0).
send(Out, Filename, Offset, Count) ->
    Count2 = case Count of
                 0 ->
                     case file:read_file_info(Filename) of
                         {ok, #file_info{size = Size}} ->
                             Size - Offset;
                         Error ->
                             Error
                     end;
                 _ ->
                     Count
             end,
    case Count2 of
        {error, _}=Error2 ->
            Error2;
        _ ->
            case prim_inet:getfd(Out) of
                {ok, Socket_fd} ->
                    call_port(
                      list_to_binary(
                        [<<Offset:64/native, Count2:64/native,
                          Socket_fd:32/native>>, Filename, <<0:8>>]));
                Error3 ->
                    Error3
            end
    end.

call_port(Msg) ->
    ?MODULE ! {call, self(), Msg},
    receive
        {?MODULE, {data, <<Count:64/native, 1:8, _/binary>>}} ->
            {ok, Count};
        {?MODULE, {data, <<_:64/native, 0:8, Error/binary>>}} ->
            {error, list_to_atom(
                      lists:takewhile(fun(El) -> El =/= 0 end,
                                      binary_to_list(Error)))}
    end.

loop(Port) ->
    receive
        {call, Caller, Msg} ->
            erlang:port_command(Port, Msg),
            receive
                {Port, Response} ->
                    Caller ! {?MODULE, Resp}
            end,
            loop(Port);
        stop ->
            erlang:port_close(Port),
            receive {'EXIT', Port, _Reason} -> ok
            after 0 -> ok
            end;
        {'EXIT', Port , _} ->
            error_logger:format("Fatal sendfile port died ~n", []),
            exit(sendfile)
    
    end.
