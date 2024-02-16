-module(server).
-behaviour(gen_server).

-record(client, {clientSocket, clientName, clientAddress, adminStatus = false, state = online, timestamp = os:timestamp()}).
-record(message, {timestamp, senderName, text, receiver}).
-record(server_status, {listenSocket, counter, maxClients, historySize, chatTopic, config}).
-include_lib("stdlib/include/qlc.hrl").

-export([start_link/0, accept_clients/0, get_record/1, show_clients/0, print_messages/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
 

%%% gen_server callbacks

init([]) ->
    io:format("Initialising Server ~n"),
    {N,[]} =  string:to_integer(string:trim(io:get_line("Enter No of Clients Allowed : "))),
    {X,[]} =  string:to_integer(string:trim(io:get_line("Message History Size : "))),
    ChatTopic = string:trim(io:get_line("Enter Chat Topic : ")),
    {ok, ListenSocket} = gen_tcp:listen(9991, [binary, {active, true}]),
    database_init(),
    ServerStatus = #server_status{listenSocket = ListenSocket, counter = 1, maxClients = N, historySize = X, chatTopic = ChatTopic, config = restricted},
    mnesia:transaction(fun() -> mnesia:write(ServerStatus) end),
    spawn(server, accept_clients, []),
    {ok, ServerStatus}.

database_init() ->
    mnesia:start(),
    mnesia:create_table(client, [{attributes, record_info(fields, client)}]),
    mnesia:create_table(message, [{attributes, record_info(fields, message)}, {type, ordered_set}]),
    mnesia:create_table(server_status, [{attributes, record_info(fields, server_status)}]).



accept_clients() ->
    [ListenSocket | _] = mnesia:dirty_all_keys(server_status), 
    {atomic,[Row]} = mnesia:transaction(fun() ->mnesia:read(server_status, ListenSocket) end),
    MaxClients = Row#server_status.maxClients,
    HistorySize = Row#server_status.historySize,
    Counter = Row#server_status.counter,
    ChatTopic = Row#server_status.chatTopic,
    {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
    Active_clients = active_clients(),
    if
        Active_clients<MaxClients ->
            ClientName = "User"++integer_to_list(Counter),
            io:format("Accepted Connection from ~p~n",[ClientName]),
            MessageHistory = retreive_messages(HistorySize),
            gen_tcp:send(ClientSocket, term_to_binary({connected, node(), ClientName, MessageHistory, ChatTopic})),
            insert_client_database(ClientSocket, ClientName),
            Message = ClientName ++ " joined the ChatRoom.",
            broadcast({ClientSocket, Message}),
            NewCounter = Counter+1,
            NewRow = Row#server_status{counter = NewCounter},
            mnesia:transaction(fun() -> mnesia:write(NewRow) end);
        true ->
            Message = "No space on server :(",
            gen_tcp:send(ClientSocket, term_to_binary({reject, Message})),
            gen_tcp:close(ClientSocket)
    end,
    accept_clients().

handle_call(Request,From, ServerStatus) ->
    [ListenSocket | _] = mnesia:dirty_all_keys(server_status),
    {ClientAddress, _} = From,
    {client, ClientSocket, ClientName, _ClientAddress,_AdminStatus, _State , _TimeStamp} = get_client_info_add(ClientAddress),
    case Request of
        {username, ClientName} ->
            Record = get_record(ClientName),
            mnesia:transaction(fun() -> mnesia:write(Record#client{clientAddress = ClientAddress}) end),
            {reply, ok, ServerStatus};
            % Private Message
        {private_message, Message, Receiver} ->
            RecSocket = getSocket(Receiver),
            case RecSocket of
                {error, _} ->
                    {reply, {error, "User not found"}, ServerStatus};
                _RecSocket ->
                    RecvState = get_state(RecSocket),
                    if
                        RecvState =:= online ->
                            io:format("Client ~p send message to ~p : ~p~n", [getUserName(ClientSocket), Receiver, Message]),
                            broadcast({ClientSocket, Message}, Receiver),
                            {reply, {success, "Message Sent"}, ServerStatus};
                        true ->
                            SenderName = getUserName(ClientSocket),
                            Msg = "Receiver is Oflline, he will be notified later.",
                            insert_message_database(SenderName, Message, Receiver),
                            io:format("~s~n",[Msg]),
                            {reply, {warning, Msg}, ServerStatus}
                    end
            end,
            {reply, ok, ServerStatus};
        % Broadcast Message
        {message, Message} ->
            io:format("Received from ~p: ~s~n",[getUserName(ClientSocket),Message]),
            broadcast({ClientSocket,Message}),
            {reply, ok, ServerStatus};
        % Send list of Active Clients 
        {show_clients} ->
            List = retreive_clients(),
            {reply, {List}, ServerStatus};
        % Client going offline
        {offline} ->
            Message = getUserName(ClientSocket) ++ " is offline now.",
            update_state(ClientSocket, offline),
            broadcast({ClientSocket, Message}),
            {reply, ok, ServerStatus};
        % Client going online
        {online} ->
            Message = getUserName(ClientSocket) ++ " is online now.",
            Last_Active = update_state(ClientSocket, online),
            broadcast({ClientSocket, Message}),
            Prev_messages = get_old_messages(ClientSocket, Last_Active),
            {reply, {previous, Prev_messages}, ServerStatus};
        % Get Chat Topic
        {topic} ->
            Topic = get_chat_topic(ListenSocket),
            {reply, {topic, Topic}, ServerStatus};
        %Change Chat Topic
        {change_topic, NewTopic}->
            Trans = fun() -> mnesia:read({client, ClientSocket}) end,
            {atomic, [Row]} = mnesia:transaction(Trans),
            Trans2 = fun() -> mnesia:read({server_status, ListenSocket}) end,
            {atomic, [Record]} = mnesia:transaction(Trans2),
            Config = Record#server_status.config,
            AdminStatus = Row#client.adminStatus,
            if
                AdminStatus == true orelse Config == open ->
                    update_chat_topic(NewTopic, ListenSocket),
                    {reply,{success}, ServerStatus},
                    Message = "Chat Topic Updated to " ++ NewTopic,
                    broadcast({ClientSocket, Message});
                true ->
                    {reply, {failed}, ServerStatus}
            end,
            {reply, ok, ServerStatus};
        % Exit from ChatRoom
        {exit} ->
            ClientName = getUserName(ClientSocket),
            io:format("Client ~p left the ChatRoom.~n",[ClientName]),
            LeavingMessage = ClientName ++ " left the ChatRoom.",
            broadcast({ClientSocket, LeavingMessage}),
            remove_client(ClientSocket),
            {reply, ok, ServerStatus};
        _ -> 
            {reply, ok, ServerStatus}
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
    X = lists:filter(fun({client, _Socket, _Name, Address}) ->
        Address == ClientAddress end, ClientList),
    [ClientStatus | _] = X,
    ClientStatus.


get_record(ClientName) ->
    F = fun() -> qlc:e(qlc:q([M || M <- mnesia:table(client)])) end,
    {atomic, Query} = mnesia:transaction(F),
    % io:format("Query : ~p~n",[Query]),
    [Row | _] =  lists:filter(fun({client,_,Name, _}) ->
            Name == ClientName
        end, Query),
    Row.

broadcast({SenderSocket, Message}, Receiver) ->
    % private messages don't get saved in the database
    RecSocket = getSocket(Receiver),
    SenderName = getUserName(SenderSocket),
    insert_message_database(SenderName, Message, Receiver),
    case RecSocket of
        {error, not_found} ->
            gen_tcp:send(SenderSocket, term_to_binary({error, "User not found"}));
        RecSocket ->
            io:format("RecScoket : ~p, Sendername : ~p~n",[RecSocket, SenderName]),
            gen_tcp:send(RecSocket, term_to_binary({message, SenderName, Message})),
            gen_tcp:send(SenderSocket, term_to_binary({success, "Message Succesfully Sent"}))
    end.

broadcast({SenderSocket, Message}) ->
    SenderName = getUserName(SenderSocket),
    insert_message_database(SenderName, Message, "All"),
    Keys = mnesia:dirty_all_keys(client),
    io:format("Keys : ~p~n",[Keys]),
    lists:foreach(fun(ClientSocket) ->
        State = get_state(ClientSocket),
        case State of
            online ->
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
                end;
            _ -> ok
        end
    end, Keys).

compare_timestamps({MegaSeconds1, Seconds1, Microseconds1}, {MegaSeconds2, Seconds2, Microseconds2}) ->
    if
        MegaSeconds1 < MegaSeconds2 ->
            less;
        MegaSeconds1 > MegaSeconds2 ->
            greater;
        Seconds1 < Seconds2 ->
            less;
        Seconds1 > Seconds2 ->
            greater;
        Microseconds1 < Microseconds2 ->
            less;
        Microseconds1 > Microseconds2 ->
            greater;
        true ->
            equal
    end.
            

get_old_messages(ClientSocket, Last_Active) ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(message)]))
    end,
    {atomic, Query} = mnesia:transaction(F),
    ReceiverName = getUserName(ClientSocket),
    Filtered = lists:filter(
        fun({message,Timestamp,SenderName,_,Receiver}) ->
                (Receiver == ReceiverName) andalso SenderName /= ReceiverName  andalso compare_timestamps(Timestamp, Last_Active) =:= greater 
            end, Query),
    Final = lists:map(
            fun({message,_, SenderName, Text, _}) ->
                Msg = SenderName ++ " : " ++ Text,
                Msg
            end, Filtered),
    Final.

get_chat_topic(ListenSocket) ->
    Trans = fun() -> mnesia:read({server_status, ListenSocket}) end,
    {atomic, [Row]} = mnesia:transaction(Trans),
    Row#server_status.chatTopic.

update_chat_topic(NewTopic, ListenSocket) ->
    {atomic, [Row]} = mnesia:transaction(fun() -> mnesia:read({server_status, ListenSocket}) end),
    UpdatedRecord = Row#server_status{chatTopic = NewTopic},
    mnesia:transaction(fun()->mnesia:write(UpdatedRecord) end).

update_state(ClientSocket, State) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end,
    {atomic, [Row]} = mnesia:transaction(Trans),
    UpdatedRecord = Row#client{state = State, timestamp = os:timestamp()},
    mnesia:transaction(fun() -> mnesia:write(UpdatedRecord) end),
    Row#client.timestamp.

get_state(ClientSocket) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end,
    {atomic, [Row]} = mnesia:transaction(Trans),
    Row#client.state.

getSocket(Name) ->
    Query = qlc:q([User#client.clientSocket || User <- mnesia:table(client), User#client.clientName == Name]),
    Trans = mnesia:transaction(fun() -> qlc:e(Query) end),
    case Trans of
        {atomic, [Socket]} ->
            Socket;
        _ ->
            {error, not_found}
    end.

getUserName(ClientSocket) ->
    Trans = fun() -> mnesia:read({client, ClientSocket}) end,
    {atomic, [Row]} = mnesia:transaction(Trans),
    Row#client.clientName.

insert_client_database(ClientSocket, ClientName) ->
    ClientRecord = #client{clientSocket = ClientSocket, clientName = ClientName, state=online, timestamp = os:timestamp()},
    mnesia:transaction(
        fun() -> 
            mnesia:write(ClientRecord) 
        end).

insert_message_database(ClientName, Message, Receiver) ->
    MessageRecord = #message{timestamp = os:timestamp(), senderName = ClientName, text = Message, receiver = Receiver},
    mnesia:transaction(fun() ->
        mnesia:write(MessageRecord)
    end).

active_clients() ->
    Trans = fun() -> mnesia:all_keys(client) end,
    {atomic,List} = mnesia:transaction(Trans),
    No_of_clients = length(List),
    No_of_clients.


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


retreive_messages(N) ->
    F = fun() ->
        qlc:e(qlc:q([M || M <- mnesia:table(message)]))
    end,
    {atomic, Query} = mnesia:transaction(F),
    ReverseMessages = lists:sublist(lists:reverse(Query), 1, N),
    Messages = lists:reverse(ReverseMessages),
    Filtered = lists:filter(fun({message,_,_,_, Receiver}) ->  %{timestamp, senderName, text, receiver}
                            Receiver == "All"
                    end,  Messages),
    MessageHistory = lists:map(fun({message,_,SenderName,Text, _}) ->
        Msg = SenderName ++ " : " ++ Text,
        Msg end, Filtered),
    MessageHistory.

print_messages(N) ->
    Messages = retreive_messages(N),
    io:format("Messages:~n"),
    lists:foreach(fun(X) ->
        io:format("~p~n", [X]) end, Messages).

remove_client(ClientSocket) ->
    mnesia:transaction(fun() ->
        mnesia:delete({client, ClientSocket})
    end),
    gen_tcp:close(ClientSocket).
