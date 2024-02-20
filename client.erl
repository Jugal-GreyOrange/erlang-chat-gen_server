-module(client).
 
-export([start/0, listen_loop/1, offline/0, online/0, get_chat_topic/0, change_topic/0, exit/0, send_message/0, kick_user/0, mute_user/0, unmute_user/0, show_admins/0, make_admin/0, show_clients/0, send_private_message/0]).
-record(client_status, {name, serverSocket, startPid, serverNode, adminStatus = false, muteTime = os:timestamp(), muteDuration = 0, state = online}).
% -define(SERVER, server).

start() ->
    ClientStatus = #client_status{startPid = self()},
    SpawnedPid = spawn(fun() -> start_helper(ClientStatus) end),
    put(spawnedPid, SpawnedPid),
    put(startPid, self()),
    ok.

start_helper(ClientStatus) ->
    io:format("Connecting to server...~n"),
    {ok, Socket} = gen_tcp:connect('localhost', 9990, [binary, {active, true}]),
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = erlang:binary_to_term(BinaryData),
            case Data of
                {connected ,ServerNode, ClientName, MessageHistory, ChatTopic} ->
                    io:format("Successfully joined with Username : ~p~n",[ClientName]),
                    io:format("Topic of the Chatroom is : ~p~n", [ChatTopic]),
                    Len = list_size(MessageHistory),
                    if 
                        Len == 0 ->
                            io:format("No Message History ~n");
                        true ->        
                            io:format("Message History: ~n"),
                            print_list(MessageHistory)
                    end,
                    ClientStatus1 = ClientStatus#client_status{name = ClientName, serverSocket = Socket, serverNode = ServerNode},
                    gen_server:call({server, ServerNode}, {username, ClientName}),
                    listen_loop(ClientStatus1);
                {reject, Message} ->
                    io:format("~p~n", [Message])
                end;
        {tcp_closed, Socket} ->
            io:format("Not connected to the server~n")
    end.

listen_loop(ClientStatus) ->
    Socket = ClientStatus#client_status.serverSocket,
    StartPid = ClientStatus#client_status.startPid,
    ServerNode = ClientStatus#client_status.serverNode,
    State = ClientStatus#client_status.state,
    gen_tcp:recv(Socket, 0),
    receive
        {tcp, Socket, BinaryData} ->
            Data = binary_to_term(BinaryData),
            case Data of
                {message, SenderName, Message} ->
                    io:format("~p : ~p~n", [SenderName, Message]);
                {admin, NewAdminStatus} ->
                    ClientStatus1 = ClientStatus#client_status{adminStatus = NewAdminStatus},
                    case NewAdminStatus of
                        true ->
                            io:format("Admin rights received !!~n");
                        false ->
                            io:format("Admin rights revoked !!~n")
                    end,
                    listen_loop(ClientStatus1);
                {mute, NewMuteStatus, Duration} ->
                    case NewMuteStatus of
                        true ->
                            if 
                                Duration == 0 ->
                                    io:format("Unmuted !!~n");
                                true ->
                                    ClientStatus1 = ClientStatus#client_status{muteTime = os:timestamp(), muteDuration = Duration},
                                    io:format("Muted for ~p minutes~n", [Duration]),
                                    listen_loop(ClientStatus1)
                            end;
                        false ->
                            ClientStatus1 = ClientStatus#client_status{muteTime = os:timestamp(), muteDuration = 0},
                            io:format("Unmuted !!~n"),
                            listen_loop(ClientStatus1)
                    end;
                _ ->
                    io:format("Undefined message received~n")
            end;
        {tcp_closed, Socket} ->
            io:format("Connection closed~n"),
            ok;
        {StartPid, Data} ->
            case Data of
                {private_message, Message, Receiver} when State =:= online ->
                    Request = {private_message, Message, Receiver},
                    Response = gen_server:call({server, ServerNode}, Request),
                    case Response of
                        {success, _Message} ->
                            ok;
                        {warning, Msg} ->
                            io:format("~s~n",[Msg]);
                        {error, Msg} ->
                            io:format("Error : ~s~n",[Msg])
                    end;
                    % private_message_helper(ClientStatus);
                {message, Message} when State =:= online ->
                    {MuteCheck, Duration} = mute_check(ClientStatus),
                    case MuteCheck of
                        true ->
                            io:format("Muted for ~p more minutes. ~n", [Duration]);
                        false ->
                            Request = {message, Message},
                            gen_server:call({server, ServerNode}, Request),
                            ok
                    end;
                {exit} when State =:= online ->
                    Request = {exit},
                    gen_server:call({server, ServerNode}, Request);
                {make_admin, ClientName} when State =:= online ->
                    make_admin_helper(ClientStatus, ClientName);
                {offline} when State =:= online ->
                    Request = {offline},
                    gen_server:call({server, ServerNode}, Request),
                    io:format("You are Offline Now :') ~n"),
                    ClientStatus1 = ClientStatus#client_status{state = offline},
                    listen_loop(ClientStatus1);
                {online} when State =:= offline ->
                    Request = {online},
                    Response = gen_server:call({server, ServerNode}, Request),
                    io:format("You are Online Now :) ~n"),
                    ClientStatus1 = ClientStatus#client_status{state = online},
                    case Response of
                        {previous, List} ->
                            Len = list_size(List),
                            if 
                                Len == 0 ->
                                    io:format("No Prev Messages for Now ~n");
                                true ->    
                                    io:format("Old Messages : ~n"),
                                        print_list(List)
                            end;
                        _ ->
                            ok
                    end,
                    listen_loop(ClientStatus1);
                {topic} when State =:= online ->
                    Request = {topic},
                    Response = gen_server:call({server, ServerNode}, Request),
                    {topic, ChatTopic} = Response,
                    io:format("Topic of the ChatRoom is : ~p~n",[ChatTopic]);
                {change_topic, NewTopic} when State =:= online ->
                    Request = {change_topic, NewTopic},
                    Response = gen_server:call({server, ServerNode}, Request),
                    case Response of
                        {success} ->
                            io:format("Topic of the ChatRoom is updated to : ~p~n",[NewTopic]);
                        {failed} ->
                            io:format("Only Admin's can change the topic of Chat : ~n");
                        _ ->
                            io:format("Error while Changing the Topic")
                    end;
                {kick, ClientName} ->
                    kick_helper(ClientStatus, ClientName);
                {mute_user, ClientName, MuteDuration} ->
                    mute_helper(ClientStatus, ClientName, MuteDuration);
                {show_clients} when State =:= online ->
                    Request = {show_clients},
                    ClientList = _Response = gen_server:call({server, ServerNode}, Request),
                    FormattedClientList = lists:map(fun({client, _ClientSocket, ClientName, _ClientAddress, _AdminStatus, _State, _Timestamp}) ->
                        ClientName
                        end, ClientList),
                    print_list(FormattedClientList);
                {show_admins} when State =:= online ->
                    Request = {show_clients},
                    ClientList = _Response = gen_server:call({server, ServerNode}, Request),
                    FilteredClientList = lists:filter(fun({client, _ClientSocket, _ClientName, _ClientAddress, AdminStatus, _State, _Timestamp}) ->
                        AdminStatus == true end, ClientList),
                    FormattedAdminClientList = lists:map(fun({client, _ClientSocket, ClientName, _ClientAddress, _AdminStatus, _State, _Timestamp}) ->
                        ClientName
                        end, FilteredClientList),
                    print_list(FormattedAdminClientList);
                _ ->
                    io:format("Undefined internal message received~n")
            end
    end,
    listen_loop(ClientStatus).

make_admin_helper(ClientStatus, ClientName) ->
    AdminStatus = ClientStatus#client_status.adminStatus,
    ServerNode = ClientStatus#client_status.serverNode,
    case AdminStatus of
        true ->
            Response = gen_server:call({server, ServerNode}, {make_admin, ClientName}),
            case Response of
                {success} ->
                    ok;
                {error, Message} ->
                    io:format("error: ~p~n", [Message])
            end;
        false ->
            io:format("Admin rights not available~n")
    end.

kick_helper(ClientStatus, ClientName) ->
    AdminStatus = ClientStatus#client_status.adminStatus,
    ServerNode = ClientStatus#client_status.serverNode,
    case AdminStatus of
        true ->
            Response = gen_server:call({server, ServerNode}, {kick, ClientName}),
            case Response of
                {success} ->
                    ok;
                {error, Message} ->
                    io:format("error: ~p~n", [Message])
            end;
        false ->
            io:format("Admin rights not available~n")
    end.

mute_helper(ClientStatus, ClientName, MuteDuration) ->
    ServerNode = ClientStatus#client_status.serverNode,
    AdminStatus = ClientStatus#client_status.adminStatus,
    case AdminStatus of
        true ->
            Response = gen_server:call({server, ServerNode}, {mute_user, ClientName, MuteDuration}),
            case Response of
                {success} ->
                    ok;
                {error, Message} ->
                    io:format("error: ~p~n", [Message])
            end;
        false ->
            io:format("Admin rights not available~n")
    end.

%--------------user functions----------------

send_message() ->
    Message = string:trim(io:get_line("Enter message: ")),
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {message, Message}},
    ok.

send_private_message() ->
    Message = string:trim(io:get_line("Enter message: ")),
    Receiver = string:trim(io:get_line("Enter receiver name: ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {private_message, Message, Receiver}},
    ok.

print_list(List) ->
    lists:foreach(fun(X) ->
        io:format("~p~n", [X]) end, List).

list_size(L) ->
    list_size(L,0).

list_size([_ | Rest], Count) ->
    list_size(Rest, Count+1);

list_size([], Count) ->
    Count.

mute_check(ClientStatus) ->
    {_, TimeNow, _} = os:timestamp(),
    MuteDuration = ClientStatus#client_status.muteDuration,
    {_, TimeOfMute, _} = ClientStatus#client_status.muteTime,
    TimeSinceMute = (TimeNow - TimeOfMute)/(60),
    TimeLeft = MuteDuration - TimeSinceMute,
    case (TimeLeft > 0) of
        true ->
            {true, TimeLeft};   % still mute
        false ->
            {false, 0}      % mute time ended
    end.



kick_user() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {kick, ClientName}},
    ok.

make_admin() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {make_admin, ClientName}},
    ok.

show_admins() ->
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {show_admins}},
    ok.

mute_user() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    {MuteDuration, []} = string:to_integer(string:trim(io:get_line("Mute Duration (in minutes): "))),
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {mute_user, ClientName, MuteDuration}},
    ok.

unmute_user() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {mute_user, ClientName, 0}},
    ok.

show_clients() ->
    StartPid = self(),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {show_clients}},
    ok.

offline() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {offline}},
    ok.

online() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {online}},
    ok.

exit() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {exit}},
    ok.

change_topic() ->
    Topic = string:trim(io:get_line("Enter New Topic : ")),
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {change_topic, Topic}},
    ok.

get_chat_topic() ->
    StartPid = get(startPid),
    SpawnedPid = get(spawnedPid),
    SpawnedPid ! {StartPid, {topic}},
    ok.



%-------------helper functions-----------------
