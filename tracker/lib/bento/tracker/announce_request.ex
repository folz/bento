defmodule Bento.Tracker.AnnounceRequest do
  @moduledoc """
  The parsed parameters from an announce request.
  """

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Event
  alias Bento.Tracker.InfoHash
  alias Bento.Tracker.IP
  alias Bento.Tracker.Params
  alias Bento.Tracker.Peer

  @enforce_keys [:info_hash, :peer]
  defstruct event: :none,
            info_hash: nil,
            compact?: false,
            event_provided?: false,
            numwant_provided?: false,
            ip_provided?: false,
            numwant: 0,
            left: 0,
            downloaded: 0,
            uploaded: 0,
            peer: nil,
            params: nil

  @type t :: %__MODULE__{
          event: Event.t(),
          info_hash: InfoHash.t(),
          compact?: boolean(),
          event_provided?: boolean(),
          numwant_provided?: boolean(),
          ip_provided?: boolean(),
          numwant: non_neg_integer(),
          left: non_neg_integer(),
          downloaded: non_neg_integer(),
          uploaded: non_neg_integer(),
          peer: Peer.t(),
          params: Params.t() | nil
        }

  @err_invalid_ip ClientError.new("invalid IP")
  @err_invalid_port ClientError.new("invalid port")

  @doc """
  Enforces a max and default numwant and coerces the peer's IP address
  into the proper format.

  IPv4 addresses (including IPv4-mapped IPv6 addresses) are normalized to
  4-tuples; any other address must be a valid IPv6 8-tuple.
  """
  @spec sanitize(t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, ClientError.t()}
  def sanitize(request, max_numwant, default_numwant)

  def sanitize(%__MODULE__{peer: %Peer{port: 0}}, _max_numwant, _default_numwant) do
    {:error, @err_invalid_port}
  end

  def sanitize(%__MODULE__{} = request, max_numwant, default_numwant) do
    request =
      cond do
        not request.numwant_provided? -> %{request | numwant: default_numwant}
        request.numwant > max_numwant -> %{request | numwant: max_numwant}
        true -> request
      end

    case sanitize_ip(request.peer.ip) do
      {:ok, ip} -> {:ok, %{request | peer: %{request.peer | ip: ip}}}
      :error -> {:error, @err_invalid_ip}
    end
  end

  defp sanitize_ip(ip) when is_tuple(ip) do
    case IP.to4(ip) do
      {_, _, _, _} = ip4 -> {:ok, ip4}
      nil -> if tuple_size(ip) == 8, do: {:ok, ip}, else: :error
    end
  end

  defp sanitize_ip(_ip), do: :error
end
