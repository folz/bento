defmodule Bento.Tracker.HTTP.Parser do
  @moduledoc """
  Parses announce and scrape requests from HTTP requests.

  A request is represented as a `Bento.Tracker.HTTP.Request` struct
  carrying the raw request target, the header map, and the connection's
  remote IP. IP resolution mirrors chihaya: with `:allow_ip_spoofing`,
  the `ip`/`ipv4`/`ipv6` query parameters win; otherwise a configured
  `:real_ip_header` wins; otherwise the connection's remote address is
  used.
  """

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Event
  alias Bento.Tracker.HTTP.Request
  alias Bento.Tracker.Params
  alias Bento.Tracker.Peer
  alias Bento.Tracker.ScrapeRequest

  @default_max_numwant 100
  @default_default_numwant 50
  @default_max_scrape_infohashes 50

  @doc "The default parser options."
  @spec default_options() :: map()
  def default_options do
    %{
      allow_ip_spoofing: false,
      real_ip_header: "",
      max_numwant: @default_max_numwant,
      default_numwant: @default_default_numwant,
      max_scrape_infohashes: @default_max_scrape_infohashes
    }
  end

  @doc "Parses an announce request from an HTTP request."
  @spec parse_announce(Request.t(), map()) ::
          {:ok, AnnounceRequest.t()} | {:error, ClientError.t()}
  def parse_announce(%Request{} = request, opts) do
    opts = Map.merge(default_options(), opts)

    with {:ok, params} <- Params.parse_url_data(request.target),
         {:ok, event, event_provided?} <- parse_event(params),
         {:ok, info_hash} <- parse_info_hash(params),
         {:ok, peer_id} <- parse_peer_id(params),
         {:ok, left} <- parse_uint(params, "left"),
         {:ok, downloaded} <- parse_uint(params, "downloaded"),
         {:ok, uploaded} <- parse_uint(params, "uploaded"),
         {:ok, numwant, numwant_provided?} <- parse_numwant(params),
         {:ok, port} <- parse_port(params),
         {:ok, ip, ip_provided?} <- requested_ip(request, params, opts) do
      announce = %AnnounceRequest{
        params: params,
        event: event,
        event_provided?: event_provided?,
        info_hash: info_hash,
        compact?: compact?(params),
        left: left,
        downloaded: downloaded,
        uploaded: uploaded,
        numwant: numwant,
        numwant_provided?: numwant_provided?,
        ip_provided?: ip_provided?,
        peer: %Peer{id: peer_id, ip: ip, port: port}
      }

      AnnounceRequest.sanitize(announce, opts.max_numwant, opts.default_numwant)
    end
  end

  @doc "Parses a scrape request from an HTTP request."
  @spec parse_scrape(Request.t(), map()) ::
          {:ok, ScrapeRequest.t()} | {:error, ClientError.t()}
  def parse_scrape(%Request{} = request, opts) do
    opts = Map.merge(default_options(), opts)

    with {:ok, params} <- Params.parse_url_data(request.target),
         info_hashes when info_hashes != [] <- Params.info_hashes(params) do
      scrape = %ScrapeRequest{info_hashes: info_hashes, params: params}
      ScrapeRequest.sanitize(scrape, opts.max_scrape_infohashes)
    else
      [] -> {:error, ClientError.new("no info_hash parameter supplied")}
      {:error, _reason} = error -> error
    end
  end

  defp parse_event(params) do
    case Params.string(params, "event") do
      {:ok, event_str} ->
        case Event.new(event_str) do
          {:ok, event} -> {:ok, event, true}
          {:error, _reason} -> {:error, ClientError.new("failed to provide valid client event")}
        end

      :error ->
        {:ok, :none, false}
    end
  end

  defp compact?(params) do
    case Params.string(params, "compact") do
      {:ok, value} -> value != "" and value != "0"
      :error -> false
    end
  end

  defp parse_info_hash(params) do
    case Params.info_hashes(params) do
      [] -> {:error, ClientError.new("no info_hash parameter supplied")}
      [info_hash] -> {:ok, info_hash}
      _multiple -> {:error, ClientError.new("multiple info_hash parameters supplied")}
    end
  end

  defp parse_peer_id(params) do
    case Params.string(params, "peer_id") do
      :error -> {:error, ClientError.new("failed to parse parameter: peer_id")}
      {:ok, peer_id} when byte_size(peer_id) == 20 -> {:ok, peer_id}
      {:ok, _wrong_size} -> {:error, ClientError.new("failed to provide valid peer_id")}
    end
  end

  defp parse_uint(params, key) do
    case Params.uint(params, key, 64) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, ClientError.new("failed to parse parameter: #{key}")}
    end
  end

  defp parse_numwant(params) do
    case Params.uint(params, "numwant", 32) do
      {:ok, numwant} -> {:ok, numwant, true}
      {:error, :key_not_found} -> {:ok, 0, false}
      {:error, _reason} -> {:error, ClientError.new("failed to parse parameter: numwant")}
    end
  end

  defp parse_port(params) do
    case Params.uint(params, "port", 16) do
      {:ok, port} -> {:ok, port}
      {:error, _reason} -> {:error, ClientError.new("failed to parse parameter: port")}
    end
  end

  # Determines the IP address for a BitTorrent client request.
  defp requested_ip(request, params, opts) do
    spoofed =
      if opts.allow_ip_spoofing do
        ["ip", "ipv4", "ipv6"]
        |> Enum.find_value(fn key ->
          case Params.string(params, key) do
            {:ok, ip_str} -> {ip_str, true}
            :error -> nil
          end
        end)
      end

    header_ip =
      if opts.real_ip_header != "" do
        # Mirror Go's r.Header.Get: an absent header, or a header present
        # with an empty value, is ignored and we fall back to the remote
        # address rather than trying to parse "".
        case Map.fetch(request.headers, String.downcase(opts.real_ip_header)) do
          {:ok, ip_str} when ip_str != "" -> {ip_str, false}
          _absent_or_empty -> nil
        end
      end

    case spoofed || header_ip do
      {ip_str, provided?} ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {:ok, ip, provided?}
          :error -> {:error, ClientError.new("failed to parse peer IP address")}
        end

      nil ->
        # The remote address is already a parsed tuple; no round trip
        # through a string is needed.
        {:ok, request.remote_ip, false}
    end
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end
end
