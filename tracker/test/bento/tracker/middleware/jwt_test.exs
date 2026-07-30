defmodule Bento.Tracker.Middleware.JWTTest do
  # chihaya's middleware/jwt has no test file; these tests cover the
  # documented behavior: JWKs fetched from an HTTP endpoint, RS256
  # verification, and iss/aud/infohash claim validation.
  use ExUnit.Case, async: true

  alias Bento.Tracker.AnnounceRequest
  alias Bento.Tracker.AnnounceResponse
  alias Bento.Tracker.ClientError
  alias Bento.Tracker.Middleware.JWT
  alias Bento.Tracker.Params
  alias Bento.Tracker.Peer

  @err_missing_jwt %ClientError{message: "unapproved request: missing jwt"}
  @err_invalid_jwt %ClientError{message: "unapproved request: invalid jwt"}

  @issuer "test-issuer"
  @audience "test-audience"
  @kid "test-kid"

  @info_hash String.duplicate("i", 20)

  setup_all do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    other_key = :public_key.generate_key({:rsa, 2048, 65_537})

    jwks = JSON.encode!(%{"keys" => [jwk(private_key, @kid)]})
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server = spawn_link(fn -> serve_jwks(listen, jwks) end)

    {:ok, state} =
      JWT.new(%{
        issuer: @issuer,
        audience: @audience,
        jwk_set_url: "http://127.0.0.1:#{port}/jwks",
        jwk_set_update_interval: :timer.minutes(5)
      })

    on_exit(fn -> Process.exit(server, :kill) end)

    %{
      state: state,
      private_key: private_key,
      other_key: other_key,
      jwk_set_url: "http://127.0.0.1:#{port}/jwks"
    }
  end

  test "accepts a chihaya-style duration string for jwk_set_update_interval", %{
    jwk_set_url: url
  } do
    assert {:ok, state} =
             JWT.new(%{
               issuer: @issuer,
               audience: @audience,
               jwk_set_url: url,
               jwk_set_update_interval: "5m"
             })

    assert Process.alive?(state.pid)
    JWT.stop(state)
  end

  defp serve_jwks(listen, jwks) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 5000)

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(jwks)}\r\nconnection: close\r\n\r\n" <> jwks

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        serve_jwks(listen, jwks)

      {:error, _reason} ->
        :ok
    end
  end

  defp jwk(private_key, kid) do
    modulus = elem(private_key, 2)
    public_exponent = elem(private_key, 3)

    %{
      "kty" => "RSA",
      "kid" => kid,
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false),
      "e" => Base.url_encode64(:binary.encode_unsigned(public_exponent), padding: false)
    }
  end

  defp sign(claims, private_key, opts \\ []) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => Keyword.get(opts, :kid, @kid)}

    signing_input =
      Base.url_encode64(JSON.encode!(header), padding: false) <>
        "." <> Base.url_encode64(JSON.encode!(claims), padding: false)

    signature = :public_key.sign(signing_input, :sha256, private_key)
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @audience,
        "infohash" => Base.encode16(@info_hash, case: :lower)
      },
      overrides
    )
  end

  defp announce(token) do
    params =
      case token do
        nil ->
          nil

        token ->
          {:ok, params} = Params.parse_url_data("/announce?jwt=" <> token)
          params
      end

    %AnnounceRequest{
      info_hash: @info_hash,
      peer: %Peer{id: String.duplicate("p", 20), ip: {1, 2, 3, 4}, port: 1},
      params: params
    }
  end

  defp handle(state, request) do
    JWT.handle_announce(state, %{}, request, %AnnounceResponse{})
  end

  test "a valid JWT is approved", %{state: state, private_key: key} do
    assert {:ok, %{}, %AnnounceResponse{}} = handle(state, announce(sign(claims(), key)))
  end

  test "an aud array containing the audience is approved", %{state: state, private_key: key} do
    token = sign(claims(%{"aud" => ["other", @audience]}), key)
    assert {:ok, %{}, %AnnounceResponse{}} = handle(state, announce(token))
  end

  test "missing params or jwt parameter is rejected", %{state: state} do
    assert handle(state, announce(nil)) == {:error, @err_missing_jwt}

    {:ok, params} = Params.parse_url_data("/announce?port=1")
    request = %{announce("x") | params: params}
    assert handle(state, request) == {:error, @err_missing_jwt}
  end

  test "a wrong issuer is rejected", %{state: state, private_key: key} do
    token = sign(claims(%{"iss" => "evil"}), key)
    assert handle(state, announce(token)) == {:error, @err_invalid_jwt}
  end

  test "a wrong audience is rejected", %{state: state, private_key: key} do
    token = sign(claims(%{"aud" => "evil"}), key)
    assert handle(state, announce(token)) == {:error, @err_invalid_jwt}
  end

  test "a wrong infohash claim is rejected", %{state: state, private_key: key} do
    token =
      sign(claims(%{"infohash" => Base.encode16(String.duplicate("j", 20), case: :lower)}), key)

    assert handle(state, announce(token)) == {:error, @err_invalid_jwt}
  end

  test "an unknown kid is rejected", %{state: state, private_key: key} do
    token = sign(claims(), key, kid: "unknown")
    assert handle(state, announce(token)) == {:error, @err_invalid_jwt}
  end

  test "a signature from the wrong key is rejected", %{state: state, other_key: other_key} do
    token = sign(claims(), other_key)
    assert handle(state, announce(token)) == {:error, @err_invalid_jwt}
  end

  test "garbage tokens are rejected", %{state: state} do
    assert handle(state, announce("not-a-jwt")) == {:error, @err_invalid_jwt}
    assert handle(state, announce("a.b.c")) == {:error, @err_invalid_jwt}
  end

  test "an unreachable JWK endpoint fails hook creation" do
    assert {:error, _reason} =
             JWT.new(%{
               issuer: @issuer,
               audience: @audience,
               jwk_set_url: "http://127.0.0.1:1/jwks",
               jwk_set_update_interval: :timer.minutes(5)
             })
  end

  test "scrapes are not protected", %{state: state} do
    assert {:ok, %{}, %Bento.Tracker.ScrapeResponse{}} =
             JWT.handle_scrape(
               state,
               %{},
               %Bento.Tracker.ScrapeRequest{},
               %Bento.Tracker.ScrapeResponse{}
             )
  end
end
