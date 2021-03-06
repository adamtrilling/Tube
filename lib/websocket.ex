defmodule Tube.Websocket do
  alias Tube.Http.{Request, Response}
  alias Tube.Frame.{PingFrame, PongFrame, CloseFrame, TextFrame, DataFrame, ContinuationFrame}
  alias Tube.Frame
  use GenServer

  @moduledoc """
  Represents a WebSocket connection

  This GenServer will handle the whole lifecycle of one WebSocket connection.

  ## Setup
  ```
  {:ok, pid} = GenServer.start_link(Tube.Websocket,
    uri: "ws://localhost:4000/ws",
    opts: [parent: self])
  :ok = Tube.Websocket.connect(pid)
  ```

  This will open a WebSocket connection to `ws://localhost:4000/ws`.

  Incoming frames will be sent via message passing to the pid given in `opts.parent`.

  ## Messages to parent

  * `{:websocket, :frame, frame}`
  * `{:websocket, :open}`
  * `{:websocket, :closed}`
  """

  @challenge_token "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defstruct uri: nil, socket: nil, state: :closed,
            challenge_key: nil, frame_types: %{},
            initiated_close: false, opts: [],
            next_ping_timer: nil, timeout_timer: nil,
            parent: nil, old_tcp_data: "",
            incomplete_frame: nil

  defmodule Validation do
    @moduledoc false
    defstruct errors: [], valid?: true
  end

  alias Tube.Websocket.Validation

  def init([uri: uri]) do
    init(uri: uri, opts: [])
  end

  def init([uri: uri, opts: opts]) do
    frame_types = [PingFrame, PongFrame, CloseFrame, TextFrame, DataFrame, ContinuationFrame]
    |> Enum.map(fn (type) -> {type.opcode, type} end)
    |> Enum.into(%{})
    {:ok, %__MODULE__{uri: parse_uri(uri), state: :closed, frame_types: frame_types, opts: opts, parent: Keyword.get(opts, :parent)}}
  end

  @doc """
  Connects to the given `uri`
  """
  @spec connect(pid) :: :ok
  def connect(pid) do
    GenServer.call(pid, :connect)
  end

  @doc """
  Changes the uri that will be used the next time `connect/1` is called.
  """
  @spec set_uri(pid :: pid, uri :: string) :: :ok
  def set_uri(pid, uri) do
    GenServer.call(pid, {:set_uri, uri})
  end

  @doc """
  Closes the connection by sending a close frame to the server.
  """
  @spec close(pid :: pid) :: :ok
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  @doc """
  Sends a frame to the server
  """
  @spec send_frame(frame :: map, socket :: map) :: :ok
  def send_frame(%Frame{} = frame, socket) do
    bin = frame
    |> Frame.put_mask
    |> Frame.to_binary

    :ok = socket_send(socket, bin)
  end

  def send_frame(%{__struct__: type} = frame, socket) when type in [PingFrame, PongFrame, CloseFrame, TextFrame, DataFrame, ContinuationFrame] do
    frame
    |> type.to_frame
    |> send_frame(socket)
  end


  def handle_call({:set_uri, uri}, _from, %__MODULE__{state: :closed} = state) do
    {:reply, :ok, %{state | uri: parse_uri(uri)}}
  end

  defp parse_uri(uri) do
    uri = uri
    |> URI.parse

    port = case uri.port do
      nil ->
        case uri.scheme do
          "ws" -> 80
          "wss" -> 443
          _ -> nil
        end
      port -> port
    end

    %{uri | port: port}
  end

  def handle_call(:connect, _from, %__MODULE__{state: :closed, uri: uri} = state) do

    case :inet.getaddr(uri.host |> String.to_charlist, :inet) do
      {:ok, ip} ->
        case :gen_tcp.connect(ip,
            state.uri.port,
            [:binary, active: true]) do
          {:ok, socket} ->
            {:ok, socket} = case uri.scheme do
              "ws" -> socket
              "wss" ->
                :ssl.start
                :ssl.connect(socket, [])
            end
            state = %{state |
              socket: socket,
              state: :connecting
            }
            {:ok, state} = do_handshake(state)
            {:reply, :ok, state}
          {:error, reason} ->
            IO.puts "Error while connecting #{inspect reason}"
            {:reply, {:error, reason}, state}
        end
      {:error, error} ->
        {:reply, {:error, :dns, error}, state}
    end

  end

  def socket_send({:sslsocket, _, _} = socket, message) do
    :ssl.send(socket, message)
  end

  def socket_send(socket, message) do
    :gen_tcp.send(socket, message)
  end

  defp do_handshake(%__MODULE__{uri: uri, socket: socket, state: :connecting} = state) do
    challenge_key = :crypto.strong_rand_bytes(16)
    request = %Request{
      uri: %{uri | scheme: case uri.scheme do
        "ws" -> "http"
        "wss" -> "https"
        _ -> uri.scheme
      end},
      method: "GET",
      body: "",
      headers: [
        {:host, uri.authority},
        {:connection, "Upgrade"},
        {"Sec-WebSocket-Version", 13},
        {"Sec-WebSocket-Key", challenge_key |> Base.encode64},
        {:upgrade, "websocket"},
        {:origin, "#{if uri.scheme == "ws" do "http" else "https" end }://#{uri.authority}"},
        {"User-Agent", "Mozilla/5.0 (Elixir; Tube)"}
      ]
    }

    bin = request |> Request.to_string

    socket_send(socket, bin)
    state = state
    |> Map.put(:state, :handshake)
    |> Map.put(:challenge_key, challenge_key)
    {:ok, state}
  end

  # Handshake response handling
  def handle_info({:tcp, _port, msg}, %__MODULE__{state: :handshake, challenge_key: challenge_key, parent: parent} = state) when msg != "" do
    handle_handshake_response(msg, state)
  end

  def handle_info({:ssl, _port, msg}, %__MODULE__{state: :handshake, challenge_key: challenge_key, parent: parent} = state) when msg != "" do
    handle_handshake_response(msg, state)
  end

  defp handle_handshake_response(msg, %__MODULE__{state: :handshake, challenge_key: challenge_key, parent: parent} = state) do
    msg = msg |> Response.parse
    state = case msg do
      {%Response{
        status: 101,
        headers: headers
      }, rest} = res ->
        validation = %Validation{}
        |> validate_header(headers, "connection", "upgrade")
        |> validate_header(headers, "upgrade", "websocket")
        |> validate_challenge_response(headers, challenge_key)
        #TODO extensions
        #TODO protocols

        if (validation.valid?) do
          send parent, {:websocket, :open}
          if byte_size(rest) > 0 do
            state = handle_frame_msg(rest, state)
          end
          %{state | state: :open}
        else
          IO.warn "Response not valid: #{inspect validation.errors}"
          #close self
          state
        end
      _ ->
        IO.warn("Unexpected response #{inspect msg}")
        #close self #TODO terminate?
        state
    end

    #TODO 301 redirect
    {:noreply, state}
  end

  defp put_error(%Validation{} = struct, error) do
    %{struct |
      valid?: false,
      errors: [error | struct.errors]
    }
  end

  defp validate_header(%Validation{} = struct, headers, key, value) do
    case Map.get(headers, key, "") |> String.downcase do
      "" ->
        put_error(struct, "#{key} not found in headers")
      ^value ->
        struct
      _ ->
        put_error(struct, "#{key} was not '#{value}'")
    end
  end

  defp validate_challenge_response(%Validation{} = struct, headers, challenge_key) do
    expected_challenge_response =
      ((challenge_key |> Base.encode64) <> @challenge_token)
      |> :crypto.sha
      |> Base.encode64
    if (expected_challenge_response != Map.get(headers, "sec-websocket-accept")) do
      put_error(struct, "Challenge response was invalid.")
    else
      struct
    end
  end


  defp fail(pid, reason \\ "") do
    IO.puts "! ! ! Failing, because: #{reason}"
    close_frame = %CloseFrame{
      status_code: 1002,
      reason: reason
    }

    GenServer.cast(pid, {:send, close_frame})

    # Force close TCP socket if server doesn't reply in timely fashion
    Process.send_after pid, :force_close, 10000
  end

  def handle_cast({:send, %Frame{} = frame}, %__MODULE__{state: :open, socket: socket} = state) do
    send_frame(frame, socket)
    {:noreply, state}
  end


  def handle_cast({:send, %CloseFrame{} = frame}, %__MODULE__{state: ws_state, socket: socket} = state) when ws_state in [:open, :closing] do
    state = %{state | state: :closing, initiated_close: true}
    send_frame(frame, socket)
    {:noreply, state}
  end

  def handle_cast({:send, frame}, %__MODULE__{state: ws_state} = state) when ws_state != :open do
    IO.warn "tried to send frame when state was #{ws_state}."
    {:noreply, state}
  end

  def handle_cast({:send, %{__struct__: frame_type} = frame}, %__MODULE__{state: :open, socket: socket} = state) do
    send_frame(frame, socket)
    {:noreply, state}
  end

  def handle_cast(:close, %__MODULE__{state: state, socket: socket} = st) when state != :closed do
    GenServer.cast self, {:send, %CloseFrame{}}
    st = %{st | initiated_close: true}
    {:noreply, st}
  end

  def handle_info(:force_close, %__MODULE__{socket: nil} = state), do: {:noreply, state}

  def handle_info(:force_close, %__MODULE__{socket: socket} = state) do
    :gen_tcp.close(state.socket)

    state = clean_state(state)
    {:noreply, state}
  end

  defp handle_frame_msg(msg, %__MODULE__{state: ws_state, frame_types: frame_types, parent: parent, old_tcp_data: previous_msg} = state) do
    msg = previous_msg <> msg
    if byte_size(msg) >= 2 do
      case Frame.parse(msg) do
        {:ok, frame, rest} ->
          parsed_frame = case Map.get(frame_types, frame.opcode) do
            nil ->
              fail self, "Unknown opcode"
              nil
            frame_type ->
              case frame_type.parse(frame.payload) do
                {:ok, parsed_frame} ->
                  parsed_frame
                {:error, error} ->
                  fail(self, error)
                  nil
              end
          end
          state = if parsed_frame do
            {state, parsed_frame} = case {parsed_frame, frame, state.incomplete_frame} do
              {%ContinuationFrame{}, frame, nil} ->
                #IO.inspect frame
                fail self, "Got continuation frame without prior frame"
                {state, nil}
              {%ContinuationFrame{}, %{fin: false}, incomplete} ->
                #IO.puts "Got continued fragmented frame"
                incomplete = incomplete
                |> incomplete.__struct__.merge(parsed_frame)
                state = %{state | incomplete_frame: incomplete}
                {state, nil}
              {%ContinuationFrame{}, %{fin: true}, incomplete} ->
                #IO.puts "Got last fragmented frame"
                state = %{state | incomplete_frame: nil}
                parsed_frame = incomplete.__struct__.merge(incomplete, parsed_frame)
                {state, parsed_frame}
              {parsed_frame, %{fin: false}, nil} ->
                #IO.puts "Got first fragmented frame"
                state = %{state | incomplete_frame: parsed_frame}
                {state, nil}
              {_, %{fin: true, control_frame?: false}, incomplete} when incomplete != nil ->
                fail self, "Got new frame before old incomplete frame was completed"
                {state, nil}
              {_, _, _} ->
                #IO.puts "Got normal frame"
                {state, parsed_frame}
            end
            if parsed_frame do
              valid? = if parsed_frame.__struct__ == TextFrame do
                case TextFrame.validate(parsed_frame) do
                  :ok -> true
                  {:error, error} ->
                    fail self, error
                    false
                end
              else
                true
              end
              if valid? do
                send parent, {:websocket, :frame, parsed_frame}
                Tube.FrameHandler.handle_frame(parsed_frame, state)
              else
                state
              end
            else
              state
            end
          else
            state
          end
          state = if byte_size(rest) >= 2 do
            handle_frame_msg(rest, state)
          else
            %{state | old_tcp_data: rest}
          end

          state
        {:error, error} when error in [:incomplete_header, :not_enough_payload] ->
          state = %{state | old_tcp_data: msg}
          state
        {:error, :invalid_header} ->
          fail self, "Invalid header"
          state
      end
    else
      # save for later
      state = %{state | old_tcp_data: msg}
      state
    end
  end

  def handle_info({:ssl, _port, msg}, %__MODULE__{state: ws_state, frame_types: frame_types, parent: parent, old_tcp_data: previous_msg} = state) when ws_state in [:open, :closing] do
    {:noreply, handle_frame_msg(msg, state)}
  end

  def handle_info({:tcp, port, msg}, %__MODULE__{state: ws_state, frame_types: frame_types, parent: parent, old_tcp_data: previous_msg} = state) when ws_state in [:open, :closing] do
    {:noreply, handle_frame_msg(msg, state)}
  end

  def handle_info({:tcp, _port, ""}, state), do: {:noreply, state}

  def handle_info({:ssl, _port, ""}, state), do: {:noreply, state}

  def handle_cast(:schedule_ping, %__MODULE__{next_ping_timer: timer, opts: opts}) do

  end

  defp clean_state(state) do
    Map.merge(%__MODULE__{}, Map.drop(state, [
      :state,
      :socket,
      :challenge_key,
      :initiated_close,
      :old_tcp_data,
      :incomplete_frame
    ]))
  end

  def handle_info({:tcp_closed, _port}, %__MODULE__{parent: parent} = state) do
    state = clean_state(state)

    send parent, {:websocket, :closed}
    {:noreply, state}
  end
end
