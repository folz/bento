defmodule Bento.Tracker.HTTP.Writer do
  @moduledoc """
  Builds the bencoded bodies of HTTP tracker responses (BEP 3, BEP 23).

  All dictionaries are encoded with `Bento`, so keys are emitted in
  canonical byte-wise sorted order as BEP 3 mandates (chihaya relies on
  Go's randomized map order instead, which is valid but non-canonical).
  """

  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.IP
  alias Bento.Tracker.Peer
  alias Bento.Tracker.ScrapeResponse

  @doc """
  Communicates an error to a BitTorrent client. Client errors expose
  their message; any other error becomes `"internal server error"`.
  """
  @spec write_error(term()) :: iodata()
  def write_error(error) do
    message =
      case error do
        %ClientError{message: message} -> message
        _internal -> "internal server error"
      end

    Bento.encode!(%{"failure reason" => message})
  end

  @doc "Communicates the results of an announce to a BitTorrent client."
  @spec write_announce_response(AnnounceResponse.t()) :: iodata()
  def write_announce_response(%AnnounceResponse{} = response) do
    base = %{
      "complete" => response.complete,
      "incomplete" => response.incomplete,
      "interval" => response.interval,
      "min interval" => response.min_interval
    }

    dict =
      if response.compact? do
        base
        |> maybe_put("peers", compact_peers(response.ipv4_peers, &compact4/1))
        |> maybe_put("peers6", compact_peers(response.ipv6_peers, &compact6/1))
      else
        peers = Enum.map(response.ipv4_peers ++ response.ipv6_peers, &peer_dict/1)
        Map.put(base, "peers", peers)
      end

    Bento.encode!(dict)
  end

  @doc "Communicates the results of a scrape to a BitTorrent client."
  @spec write_scrape_response(ScrapeResponse.t()) :: iodata()
  def write_scrape_response(%ScrapeResponse{} = response) do
    files =
      Map.new(response.files, fn scrape ->
        {scrape.info_hash, %{"complete" => scrape.complete, "incomplete" => scrape.incomplete}}
      end)

    Bento.encode!(%{"files" => files})
  end

  defp maybe_put(dict, _key, ""), do: dict
  defp maybe_put(dict, key, value), do: Map.put(dict, key, value)

  defp compact_peers(peers, encode) do
    IO.iodata_to_binary(Enum.map(peers, encode))
  end

  defp compact4(%Peer{ip: ip, port: port}) do
    case IP.to4(ip) do
      {a, b, c, d} -> <<a, b, c, d, port::16-big>>
      nil -> raise ArgumentError, "non-IPv4 IP for Peer in ipv4_peers"
    end
  end

  defp compact6(%Peer{ip: ip, port: port}) when tuple_size(ip) == 8 do
    <<IP.to_binary(ip)::binary, port::16-big>>
  end

  defp compact6(%Peer{ip: {a, b, c, d}, port: port}) do
    # An IPv4 address expressed as its IPv4-mapped IPv6 form (::ffff:a.b.c.d).
    <<0::80, 0xFFFF::16, a, b, c, d, port::16-big>>
  end

  defp peer_dict(%Peer{} = peer) do
    %{
      "peer id" => peer.id,
      "ip" => IP.to_string(peer.ip),
      "port" => peer.port
    }
  end
end
