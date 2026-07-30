defmodule Bento.Tracker.UDP.Writer do
  @moduledoc """
  Builds the UDP response packets described in BEP 15.

  Every packet begins with a 4-byte big-endian action followed by the
  4-byte transaction ID echoed from the request.
  """

  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.IP
  alias Bento.Tracker.Peer
  alias Bento.Tracker.ScrapeResponse

  @connect_action 0
  @announce_action 1
  @scrape_action 2
  @error_action 3
  @announce_v6_action 4

  @doc "Encodes a connect response: action 0, txID, connection ID."
  @spec write_connection_id(binary(), binary()) :: iodata()
  def write_connection_id(tx_id, connection_id) do
    [header(@connect_action, tx_id), connection_id]
  end

  @doc """
  Encodes an error response: action 3, txID, the failure reason and a
  trailing NUL byte. Client errors expose their message; any other error
  is wrapped as an internal error.
  """
  @spec write_error(binary(), term()) :: iodata()
  def write_error(tx_id, error) do
    message =
      case error do
        %ClientError{message: message} -> message
        other -> "internal error occurred: #{format_error(other)}"
      end

    [header(@error_action, tx_id), message, 0]
  end

  @doc """
  Encodes an announce response (BEP 15). The peers written are the IPv6
  or IPv4 peers depending on `v6_peers?`; the action is 4 when
  `v6_action?` is set, otherwise 1.
  """
  @spec write_announce(binary(), AnnounceResponse.t(), boolean(), boolean()) :: iodata()
  def write_announce(tx_id, %AnnounceResponse{} = response, v6_action?, v6_peers?) do
    action = if v6_action?, do: @announce_v6_action, else: @announce_action
    peers = if v6_peers?, do: response.ipv6_peers, else: response.ipv4_peers

    [
      header(action, tx_id),
      <<response.interval::32-big, response.incomplete::32-big, response.complete::32-big>>,
      Enum.map(peers, &compact_peer/1)
    ]
  end

  @doc "Encodes a scrape response (BEP 15): action 2, txID and per-file counts."
  @spec write_scrape(binary(), ScrapeResponse.t()) :: iodata()
  def write_scrape(tx_id, %ScrapeResponse{} = response) do
    files =
      Enum.map(response.files, fn scrape ->
        <<scrape.complete::32-big, scrape.snatches::32-big, scrape.incomplete::32-big>>
      end)

    [header(@scrape_action, tx_id), files]
  end

  defp header(action, tx_id), do: <<action::32-big, tx_id::binary>>

  defp compact_peer(%Peer{ip: ip, port: port}) do
    <<IP.to_binary(ip)::binary, port::16-big>>
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error)
end
