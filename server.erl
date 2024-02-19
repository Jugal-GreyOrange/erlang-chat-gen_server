-module(server).
-behaviour(gen_server).

-record(client, {clientSocket, clientName, clientAddress, adminStatus = false}).
-record(server_status, {listenSocket, counter}).
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0, accept_clients/0, get_record/1, show_clients/0, make_admin/0, remove_admin/0, mute_user/0, unmute_user/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%% gen_server callbacks

init([]) ->
    io:format("Initialising Server ~n"),
    {ok, ListenSocket} = gen_tcp:listen(9991, [binary, {active, true}]),
    database_init(),
    ServerStatus = #server_status{listenSocket = ListenSocket, counter=1},
    mnesia:transaction(fun() -> mnesia:write(ServerStatus) end),
    spawn(server, accept_clients, []),
    {ok, ServerStatus}.

database_init() ->
    mnesia:start(),
    mnesia:create_table(client, [{attributes, record_info(fields, client)}]),
    mnesia:create_table(server_status, [{attributes, record_info(fields, server_status)}]).



accept_clients() ->
    [ListenSocket | _] = mnesia:dirty_all_keys(server_status), 
    {atomic, [Row]} = mnesia:transaction(fun() -> mnesia:read(server_status, ListenSocket) end),
    Counter = Row#server_status.counter,
    {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
    ClientName = "User"++integer_to_list(Counter),
    mnesia:transaction(fun() -> mnesia:write(#client{clientSocket = ClientSocket, clientName = ClientName}) end),
    gen_tcp:send(ClientSocket, term_to_binary({success, node(), ClientName})),
    io:format("Client Accepted~n"),
    NewCounter = Counter+1,
    NewRow = Row#server_status{counter = NewCounter},
    mnesia:transaction(fun() -> mnesia:write(NewRow) end),
    accept_clients().

handle_call(Request,From, ServerStatus) ->
    {ClientAddress, _} = From,
    case Request of
        {message, Message} ->
            {client, _, ClientName, _, _} = get_client_info_add(ClientAddress),
            io:format("~p : ~p~n", [ClientName, Message]),
            broadcast(ClientAddress, Message),
            {reply, ok, ServerStatus};
        {username, ClientName} ->
            Record = get_record(ClientName),
            mnesia:transaction(fun() -> mnesia:write(Record#client{clientAddress = ClientAddress}) end),
            {reply, ok, ServerStatus};
        {kick, KickClientName} ->
            KickClientSocket = getSocket(KickClientName),
            case KickClientSocket of
                {error, _} ->
                    Response = {error, "User " ++ KickClientName ++" does not exist"};
                _ ->
                    Response = {success},
                    KickingMessage = KickClientName ++ " was kicked from the chatroom.",
                    io:format("~p~n",[KickingMessage]),
                    broadcast(ClientAddress, KickingMessage),
                    remove_client(KickClientSocket)
            end,
            {reply, Response, ServerStatus};
        {make_admin, AdminClientName} ->
            AdminClientSocket = getSocket(AdminClientName),
            case AdminClientSocket of
                {error, _} ->
                    Response = {error, "User " ++ AdminClientName ++" does not exist"};
                _ ->
                    Response = {success},
                    make_admin(AdminClientName)
            end,
            {reply, Response, ServerStatus};
        {mute_user, MuteClientName, MuteDuration} ->
            MuteClientSocket = getSocket(MuteClientName),
            case MuteClientSocket of
                {error, _} ->
                    Response = {error, "User " ++ MuteClientName ++" does not exist"};
                _ ->
                    io:format("mute case 2~n"),
                    Response = {success},
                    io:format("Client ~p is now muted.~n",[MuteClientName]),
                    MutingMessage = MuteClientName ++ " was muted.",
                    broadcast(ClientAddress, MutingMessage),
                    io:format("93~n"),
                    mute_user(MuteClientName, MuteDuration)
            end,
            {reply, Response, ServerStatus};
        {show_clients} ->
            List = retreive_clients(),
            {reply, List, ServerStatus};
        _ -> 
            ok
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.
 
handle_info(_Info, State) ->
    {noreply, State}.
 
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.




% -----------------------------------------------------


get_client_info_add(ClientAddress) ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(client)]))
    end,
    {atomic, ClientList} = mnesia:transaction(F),
    X = lists:filter(fun({client, _Socket, _Name, Address, _}) ->
        Address == ClientAddress end, ClientList),
    [ClientStatus | _] = X,
    ClientStatus.


get_record(ClientName) ->
    F = fun() -> qlc:e(qlc:q([M || M <- mnesia:table(client)])) end,
    {atomic, Query} = mnesia:transaction(F),
    % io:format("Query : ~p~n",[Query]),
    [Row | _] =  lists:filter(fun({client,_,Name, _, _}) ->
            Name == ClientName
        end, Query),
    Row.

broadcast(SenderAddress, Message) ->
    io:format("140~n"),
    {client, SenderSocket, SenderName, _, _} = get_client_info_add(SenderAddress),
    io:format("142~n"),
    % insert_message_database(SenderName, Message, "All"),
    Keys = mnesia:dirty_all_keys(client),
    io:format("Keys : ~p~n",[Keys]),
    lists:foreach(fun(ClientSocket) ->
        % State = get_state(ClientSocket),
        % case State of
        %     online ->
                case ClientSocket/=SenderSocket of
                    true ->
                        case mnesia:dirty_read({client, ClientSocket}) of
                            [_] ->
                                gen_tcp:send(ClientSocket, term_to_binary({message, SenderName, Message}));
                            [] ->
                                io:format("No receiver Found ~n") 
                        end;
                    false -> 
                        ok
                end
        %     _ -> ok
        % end
    end, Keys).


retreive_clients() ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(client)]))
    end,
    {atomic, ClientList} = mnesia:transaction(F),
    ClientList.

show_clients() ->
    ClientList = retreive_clients(),
    io:format("Connected Clients:~n"),
    lists:foreach(fun(X) ->
        io:format("~p~n", [X]) end, ClientList).

make_admin() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    make_admin(ClientName).

make_admin(ClientName) ->
    ClientSocket = getSocket(ClientName),
    case ClientSocket of
        {error, _Message} ->
            io:format("No such user found~n");
        ClientSocket ->
            {atomic, [Client | _]} = mnesia:transaction(fun() -> mnesia:read({client, ClientSocket}) end),
            UpdatedClient = Client#client{adminStatus = true},
            mnesia:transaction(fun() -> mnesia:write(UpdatedClient) end),
            gen_tcp:send(ClientSocket, term_to_binary({admin, true}))
    end.

remove_admin() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    ClientSocket = getSocket(ClientName),
    case ClientSocket of
        {error, _Message} ->
            io:format("No such user found~n");
        ClientSocket ->
            Trans = fun() -> mnesia:write(#client{clientSocket = ClientSocket, clientName = ClientName, adminStatus = false}) end,
            mnesia:transaction(Trans),
            gen_tcp:send(ClientSocket, term_to_binary({admin, false}))
    end.

getUserName(ClientSocket) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end, 
    % {atomic,[Record]} = mnesia:transaction(Trans),
    % Record#client.clientName.
    Result = mnesia:transaction(Trans),
    case Result of
        {atomic, [Record]} ->
            Record#client.clientName;
        _ ->
            {error, not_found}
    end.

getSocket(Name) ->
    Query = qlc:q([User#client.clientSocket || User <- mnesia:table(client), User#client.clientName == Name]),
    Trans = mnesia:transaction(fun() -> qlc:e(Query) end),
    case Trans of
        {atomic, [Socket]} ->
            Socket;
        _ ->
            {error, not_found}
    end.

mute_user() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    {MuteDuration, []} = string:to_integer(string:trim(io:get_line("Mute Duration (in minutes): "))),
    mute_user(ClientName, MuteDuration).

mute_user(ClientName, MuteDuration) ->
    ClientSocket = getSocket(ClientName),
    case ClientSocket of
        {error, _Message} ->
            io:format("No such user found~n");
        ClientSocket ->
            gen_tcp:send(ClientSocket, term_to_binary({mute, true, MuteDuration}))
    end.

unmute_user() ->
    ClientName = string:trim(io:get_line("Enter Client Name: ")),
    ClientSocket = getSocket(ClientName),
    case ClientSocket of
        {error, _Message} ->
            io:format("No such user found~n");
        ClientSocket ->
            gen_tcp:send(ClientSocket, term_to_binary({mute, false, 0}))
    end.

remove_client(ClientSocket) ->
    mnesia:transaction(fun() ->
        mnesia:delete({client, ClientSocket})
    end),
    gen_tcp:close(ClientSocket).
