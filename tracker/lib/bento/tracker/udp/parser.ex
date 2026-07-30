defmodule Bento.Tracker.UDP.Parser do
  @moduledoc """
  Parses announce and scrape requests from UDP packets (BEP 15), including
  the optional BEP 41 URLData parameters.

  All multi-byte integers on the wire are big-endian.
  """

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.IP
  alias Bento.Tracker.Params
  alias Bento.Tracker.Peer
  alias Bento.Tracker.ScrapeRequest

  @default_max_numwant 100
  @default_default_numwant 50
  @default_max_scrape_infohashes 50

  # Event IDs as described in BEP 15.
  @event_ids {:none, :completed, :started, :stopped}

  # Option types as described in BEP 41 and BEP 45.
  @option_end_of_options 0x0
  @option_nop 0x1
  @option_url_data 0x2

  @err_malformed_packet ClientError.new("malformed packet")
  @err_malformed_ip ClientError.new("malformed IP address")
  @err_malformed_event ClientError.new("malformed event ID")
  @err_unknown_option_type ClientError.new("unknown option type")

  @doc "The malformed-packet client error."
  @spec err_malformed_packet() :: ClientError.t()
  def err_malformed_packet, do: @err_malformed_packet

  @doc "The default parser options."
  @spec default_options() :: map()
  def default_options do
    %{
      allow_ip_spoofing: false,
      max_numwant: @default_max_numwant,
      default_numwant: @default_default_numwant,
      max_scrape_infohashes: @default_max_scrape_infohashes
    }
  end

  @doc """
  Parses an announce request from a UDP packet.

  When `v6_action?` is true, the announce is parsed the "old opentracker
  way" with a 16-byte IP field.
  """
  @spec parse_announce(binary(), :inet.ip_address() | nil, boolean(), map()) ::
          {:ok, AnnounceRequest.t()} | {:error, ClientError.t()}
  def parse_announce(packet, source_ip, v6_action?, opts) do
    ip_len = if v6_action?, do: 16, else: 4
    ip_end = 84 + ip_len

    if byte_size(packet) < ip_end + 10 do
      {:error, @err_malformed_packet}
    else
      <<_conn_id::binary-size(16), info_hash::binary-size(20), peer_id::binary-size(20),
        downloaded::64-big, left::64-big, uploaded::64-big, _event_high::binary-size(3), event_id,
        ip_bytes::binary-size(ip_len), _key::binary-size(4), numwant::32-big, port::16-big,
        options::binary>> = packet

      with {:ok, event} <- lookup_event(event_id),
           {:ok, ip, ip_provided?} <- resolve_ip(source_ip, ip_bytes, opts),
           {:ok, params} <- handle_optional_parameters(options) do
        announce = %AnnounceRequest{
          params: params,
          event: event,
          event_provided?: true,
          info_hash: info_hash,
          numwant: numwant,
          numwant_provided?: true,
          left: left,
          downloaded: downloaded,
          uploaded: uploaded,
          ip_provided?: ip_provided?,
          peer: %Peer{id: peer_id, ip: ip, port: port}
        }

        AnnounceRequest.sanitize(announce, opts.max_numwant, opts.default_numwant)
      end
    end
  end

  defp lookup_event(event_id) when event_id < tuple_size(@event_ids) do
    {:ok, elem(@event_ids, event_id)}
  end

  defp lookup_event(_event_id), do: {:error, @err_malformed_event}

  # With spoofing enabled the client-supplied IP wins. The 4-byte field of
  # a v4-layout announce decodes to a clean IPv4 tuple here; chihaya
  # instead copies those 4 bytes over its existing (possibly 16-byte)
  # source-IP slice, which can leave a mangled address when a v4-layout
  # announce arrives over IPv6. We decode the field cleanly by length.
  defp resolve_ip(_source_ip, ip_bytes, %{allow_ip_spoofing: true}) do
    case IP.from_binary(ip_bytes) do
      {:ok, ip} -> {:ok, ip, true}
      :error -> {:error, @err_malformed_ip}
    end
  end

  defp resolve_ip(nil, _ip_bytes, _opts), do: {:error, @err_malformed_ip}
  defp resolve_ip(source_ip, _ip_bytes, _opts), do: {:ok, source_ip, false}

  @doc """
  Parses the optional BEP 41 parameters trailing an announce packet into
  a `Bento.Tracker.Params`.
  """
  @spec handle_optional_parameters(binary()) :: {:ok, Params.t()} | {:error, ClientError.t()}
  def handle_optional_parameters(packet) do
    case collect_url_data(packet, <<>>) do
      {:ok, url_data} -> Params.parse_url_data(url_data)
      {:error, _reason} = error -> error
    end
  end

  defp collect_url_data(<<>>, acc), do: {:ok, acc}
  defp collect_url_data(<<@option_end_of_options, _rest::binary>>, acc), do: {:ok, acc}
  defp collect_url_data(<<@option_nop, rest::binary>>, acc), do: collect_url_data(rest, acc)

  defp collect_url_data(
         <<@option_url_data, length, data::binary-size(length), rest::binary>>,
         acc
       ) do
    collect_url_data(rest, acc <> data)
  end

  defp collect_url_data(<<@option_url_data, _rest::binary>>, _acc) do
    # Truncated URLData option (missing length or payload).
    {:error, @err_malformed_packet}
  end

  defp collect_url_data(_packet, _acc), do: {:error, @err_unknown_option_type}

  @doc "Parses a scrape request from a UDP packet."
  @spec parse_scrape(binary(), :inet.ip_address(), map()) ::
          {:ok, ScrapeRequest.t()} | {:error, ClientError.t()}
  def parse_scrape(packet, _source_ip, opts) when byte_size(packet) < 36 do
    _ = opts
    {:error, @err_malformed_packet}
  end

  def parse_scrape(<<_header::binary-size(16), body::binary>>, _source_ip, opts) do
    if rem(byte_size(body), 20) != 0 do
      {:error, @err_malformed_packet}
    else
      info_hashes = for <<hash::binary-size(20) <- body>>, do: hash

      ScrapeRequest.sanitize(
        %ScrapeRequest{info_hashes: info_hashes},
        opts.max_scrape_infohashes
      )
    end
  end
end
