defmodule Bento.Tracker.UDP.FrontendTest do
  # End-to-end tests for the UDP frontend over a real socket, plus the
  # start/stop race check ported from chihaya's frontend_test.go
  # (TestStartStopRaceIssue437).
  use ExUnit.Case, async: false

  alias Bento.Tracker.Logic
  alias Bento.Tracker.Storage
  alias Bento.Tracker.UDP.Frontend

  @initial_connection_id <<0, 0, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80>>
  @info_hash String.duplicate("a", 20)
  @peer_id String.duplicate("p", 20)

  setup do
    {:ok, store} = Storage.new("memory", %{shard_count: 4})
    logic = Logic.new(%{announce_interval: 1800, min_announce_interval: 900}, store)
    config = %{addr: "127.0.0.1:0", private_key: "test-key"}

    {:ok, pid} = Frontend.start_link({logic, config})
    Process.unlink(pid)
    {:ok, {ip, port}} = Frontend.listen_address(pid)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])

    on_exit(fn ->
      :gen_udp.close(socket)

      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{ip: ip, port: port, socket: socket}
  end

  defp round_trip(socket, server_port, packet) do
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, server_port, packet)

    case :gen_udp.recv(socket, 0, 2000) do
      {:ok, {_ip, _port, response}} -> response
      {:error, reason} -> flunk("no UDP response: #{inspect(reason)}")
    end
  end

  defp connect(socket, server_port, tx_id) do
    packet = @initial_connection_id <> <<0::32-big>> <> tx_id
    response = round_trip(socket, server_port, packet)
    assert <<0::32-big, ^tx_id::binary-size(4), connection_id::binary-size(8)>> = response
    connection_id
  end

  test "connect returns a connection ID", %{port: port, socket: socket} do
    tx_id = <<1, 2, 3, 4>>
    assert byte_size(connect(socket, port, tx_id)) == 8
  end

  test "an announce with a valid connection ID returns peers", %{port: port, socket: socket} do
    tx_id = <<9, 9, 9, 9>>
    conn_id = connect(socket, port, tx_id)

    # left = 100, so the announcer is a leecher.
    announce =
      conn_id <>
        <<1::32-big>> <>
        tx_id <>
        @info_hash <>
        @peer_id <>
        <<0::64, 100::64, 0::64, 2::32-big, 0::32-big, 0::32-big, 30::32-big, 6881::16-big>>

    response = round_trip(socket, port, announce)

    assert <<1::32-big, ^tx_id::binary-size(4), interval::32-big, incomplete::32-big,
             complete::32-big, peers::binary>> = response

    assert interval == 1800
    assert incomplete == 1
    assert complete == 0
    # The announcing peer, 127.0.0.1:6881, packed as 6 bytes.
    assert peers == <<127, 0, 0, 1, 6881::16-big>>
  end

  test "an announce with a bad connection ID returns an error", %{port: port, socket: socket} do
    tx_id = <<7, 7, 7, 7>>

    announce =
      <<0::64>> <>
        <<1::32-big>> <>
        tx_id <>
        @info_hash <>
        @peer_id <>
        <<0::64, 0::64, 0::64, 0::32-big, 0::32-big, 0::32-big, 30::32-big, 6881::16-big>>

    response = round_trip(socket, port, announce)
    assert <<3::32-big, ^tx_id::binary-size(4), rest::binary>> = response
    assert rest == "bad connection ID" <> <<0>>
  end

  test "a scrape returns per-file counts", %{port: port, socket: socket} do
    tx_id = <<4, 3, 2, 1>>
    conn_id = connect(socket, port, tx_id)

    # Seed a seeder via a completed announce.
    announce =
      conn_id <>
        <<1::32-big>> <>
        tx_id <>
        @info_hash <>
        @peer_id <>
        <<0::64, 0::64, 0::64, 1::32-big, 0::32-big, 0::32-big, 30::32-big, 6881::16-big>>

    _ = round_trip(socket, port, announce)
    Process.sleep(50)

    scrape = conn_id <> <<2::32-big>> <> tx_id <> @info_hash
    response = round_trip(socket, port, scrape)

    assert <<2::32-big, ^tx_id::binary-size(4), complete::32-big, _snatches::32-big,
             incomplete::32-big>> = response

    assert complete == 1
    assert incomplete == 0
  end

  test "a packet shorter than 16 bytes gets no response", %{port: port, socket: socket} do
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, port, <<1, 2, 3>>)
    assert :gen_udp.recv(socket, 0, 200) == {:error, :timeout}
  end

  test "start then immediate stop does not race (issue 437)" do
    {:ok, store} = Storage.new("memory", %{shard_count: 4})
    logic = Logic.new(%{announce_interval: 0, min_announce_interval: 0}, store)

    {:ok, pid} = Frontend.start_link({logic, %{addr: "127.0.0.1:0"}})
    Process.unlink(pid)
    assert :ok = GenServer.stop(pid)
  end
end
