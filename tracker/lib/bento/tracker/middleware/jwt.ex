defmodule Bento.Tracker.Middleware.JWT do
  @moduledoc """
  A hook that fails an announce if the client's request is missing a
  valid JSON Web Token.

  JWTs are validated against the standard claims in RFC 7519 along with
  an extra `"infohash"` claim that verifies the client has access to the
  swarm. RS256 keys are asynchronously rotated from a provided JWK Set
  HTTP endpoint. Only RSA JWKs are supported; verification always uses
  RS256 via `:public_key`, with no third-party JOSE dependency.

  ## Options

    * `:issuer` - the expected `iss` claim
    * `:audience` - the value the `aud` claim must contain
    * `:jwk_set_url` - the HTTP endpoint serving the JWK Set
    * `:jwk_set_update_interval` - the refresh interval in milliseconds
      (default: 5 minutes)
  """

  @behaviour Bento.Tracker.Middleware.Hook

  use GenServer

  require Logger

  alias Bento.Tracker.ClientError
  alias Bento.Tracker.InfoHash
  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Params

  @err_missing_jwt ClientError.new("unapproved request: missing jwt")
  @err_invalid_jwt ClientError.new("unapproved request: invalid jwt")

  @doc "The error returned when a JWT is missing from a request."
  @spec err_missing_jwt() :: ClientError.t()
  def err_missing_jwt, do: @err_missing_jwt

  @doc "The error returned when a JWT fails to verify."
  @spec err_invalid_jwt() :: ClientError.t()
  def err_invalid_jwt, do: @err_invalid_jwt

  @impl Bento.Tracker.Middleware.Hook
  def new(options) do
    config = %{
      issuer: Middleware.get_option(options, :issuer) || "",
      audience: Middleware.get_option(options, :audience) || "",
      jwk_set_url: Middleware.get_option(options, :jwk_set_url) || "",
      jwk_set_update_interval:
        interval_ms(Middleware.get_option(options, :jwk_set_update_interval), :timer.minutes(5))
    }

    with {:ok, pid} <- GenServer.start(__MODULE__, config) do
      table = GenServer.call(pid, :table)
      {:ok, %{pid: pid, table: table, config: config}}
    end
  end

  @impl Bento.Tracker.Middleware.Hook
  def stop(%{pid: pid}) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl Bento.Tracker.Middleware.Hook
  def handle_announce(state, ctx, request, response) do
    with %Params{} = params <- request.params,
         {:ok, token} <- Params.string(params, "jwt") do
      case validate(request.info_hash, token, state.config, state.table) do
        :ok -> {:ok, ctx, response}
        {:error, _reason} -> {:error, @err_invalid_jwt}
      end
    else
      _missing -> {:error, @err_missing_jwt}
    end
  end

  @impl Bento.Tracker.Middleware.Hook
  def handle_scrape(_state, ctx, _request, response) do
    # Scrapes don't require any protection.
    {:ok, ctx, response}
  end

  ## JWK refreshing

  @impl GenServer
  def init(config) do
    table = :ets.new(__MODULE__, [:set, :public, {:read_concurrency, true}])

    Logger.debug("performing initial fetch of JWKs")

    case update_keys(config, table) do
      :ok ->
        Process.send_after(self(), :update_keys, config.jwk_set_update_interval)
        {:ok, %{config: config, table: table}}

      {:error, reason} ->
        {:stop, "failed to fetch initial JWK Set: #{inspect(reason)}"}
    end
  end

  @impl GenServer
  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end

  @impl GenServer
  def handle_info(:update_keys, state) do
    Logger.debug("performing fetch of JWKs")
    update_keys(state.config, state.table)
    Process.send_after(self(), :update_keys, state.config.jwk_set_update_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp update_keys(config, table) do
    with {:ok, body} <- http_get(config.jwk_set_url),
         {:ok, %{"keys" => jwks}} when is_list(jwks) <- JSON.decode(body),
         {:ok, keys} <- decode_keys(jwks) do
      :ets.insert(table, keys)

      stale = for {kid, _key} <- :ets.tab2list(table), not List.keymember?(keys, kid, 0), do: kid
      Enum.each(stale, &:ets.delete(table, &1))

      Logger.debug("successfully fetched JWK Set")
      :ok
    else
      {:error, reason} ->
        Logger.error("failed to fetch JWK Set: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("failed to decode JWK JSON: #{inspect(other)}")
        {:error, :invalid_jwk_set}
    end
  end

  defp http_get(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_version, _status, _reason}, _headers, body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_keys(jwks) do
    Enum.reduce_while(jwks, {:ok, []}, fn jwk, {:ok, keys} ->
      case decode_key(jwk) do
        {:ok, entry} -> {:cont, {:ok, [entry | keys]}}
        :skip -> {:cont, {:ok, keys}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_key(%{"kty" => "RSA", "kid" => kid, "n" => n, "e" => e}) do
    with {:ok, modulus} <- Base.url_decode64(n, padding: false),
         {:ok, exponent} <- Base.url_decode64(e, padding: false) do
      {:ok,
       {kid, {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}}}
    else
      :error -> {:error, :invalid_rsa_jwk}
    end
  end

  defp decode_key(%{"kty" => "RSA"}), do: {:error, :invalid_rsa_jwk}

  defp decode_key(%{"kty" => other}) do
    # chihaya only ever verifies RS256; non-RSA keys can never match.
    Logger.warning("ignoring JWK with unsupported kty #{inspect(other)}")
    :skip
  end

  defp decode_key(_jwk), do: {:error, :invalid_jwk}

  ## Validation

  defp validate(info_hash, token, config, table) do
    with {:ok, header, claims, signing_input, signature} <- parse(token),
         :ok <- check_issuer(claims, config.issuer),
         :ok <- check_audience(claims, config.audience),
         :ok <- check_info_hash(claims, info_hash),
         {:ok, public_key} <- fetch_key(header, table) do
      if :public_key.verify(signing_input, :sha256, signature, public_key) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp parse(token) do
    with [header_b64, payload_b64, signature_b64] <- String.split(token, "."),
         {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, signature} <- Base.url_decode64(signature_b64, padding: false),
         {:ok, header} when is_map(header) <- JSON.decode(header_json),
         {:ok, claims} when is_map(claims) <- JSON.decode(payload_json) do
      {:ok, header, claims, header_b64 <> "." <> payload_b64, signature}
    else
      _malformed -> {:error, :malformed_jwt}
    end
  end

  defp check_issuer(%{"iss" => issuer}, issuer) when is_binary(issuer), do: :ok
  defp check_issuer(_claims, _issuer), do: {:error, :invalid_iss_claim}

  defp check_audience(%{"aud" => audience}, audience) when is_binary(audience), do: :ok

  defp check_audience(%{"aud" => audiences}, audience) when is_list(audiences) do
    if audience in audiences, do: :ok, else: {:error, :invalid_aud_claim}
  end

  defp check_audience(_claims, _audience), do: {:error, :invalid_aud_claim}

  defp check_info_hash(%{"infohash" => claim}, info_hash) when is_binary(claim) do
    if claim == InfoHash.to_string(info_hash), do: :ok, else: {:error, :invalid_infohash_claim}
  end

  defp check_info_hash(_claims, _info_hash), do: {:error, :invalid_infohash_claim}

  defp fetch_key(%{"kid" => kid}, table) when is_binary(kid) do
    case :ets.lookup(table, kid) do
      [{^kid, public_key}] -> {:ok, public_key}
      [] -> {:error, :unknown_kid}
    end
  end

  defp fetch_key(_header, _table), do: {:error, :invalid_kid}

  # The refresh interval may be a chihaya-style duration string ("5m") or
  # an integer number of milliseconds. Unlike chihaya, we default to five
  # minutes rather than 0 (which would busy-loop re-fetching the JWK set).
  defp interval_ms(nil, default), do: default
  defp interval_ms(value, _default) when is_integer(value), do: value

  defp interval_ms(value, default) when is_binary(value) do
    case Bento.Tracker.Config.parse_duration_ms(value) do
      nil -> default
      ms -> ms
    end
  end
end
