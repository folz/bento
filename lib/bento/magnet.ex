defmodule Bento.MagnetError do
  @moduledoc """
  Raised when parsing or rendering an invalid magnet URI.
  """

  @type t :: %__MODULE__{message: String.t()}

  defexception [:message]
end

defmodule Bento.Magnet do
  @moduledoc """
  A magnet URI codec for BitTorrent (BEP-9), including v2 info-hashes
  (BEP-52) and the select-only extension (BEP-53).

  A magnet link identifies a torrent by its info-hash instead of a
  metainfo file. `parse/1` decodes a magnet URI into a struct, and
  `to_string/1` (also available via the `String.Chars` protocol) renders
  one. `from_torrent/1` builds a magnet link from the raw bytes of a
  `.torrent` file, hashing the info dictionary exactly as it appears in
  the input.

      iex> {:ok, magnet} = Bento.Magnet.parse(
      ...>   "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a" <>
      ...>     "&dn=Example+File&tr=udp%3A%2F%2Ftracker.example.com%3A80")
      iex> magnet.display_name
      "Example File"
      iex> Base.encode16(magnet.info_hash, case: :lower)
      "c12fe1c06bba254a9dc9f519b335aa7c1367a88a"
      iex> magnet.trackers
      ["udp://tracker.example.com:80"]

  ## Fields

  Struct fields map to magnet URI parameters as follows:

  | Field                 | Parameter | Notes                                          |
  |-----------------------|-----------|------------------------------------------------|
  | `info_hash`           | `xt=urn:btih:` | v1 info-hash as a raw 20-byte binary      |
  | `info_hash_v2`        | `xt=urn:btmh:` | v2 (SHA-256) info-hash as a raw 32-byte binary |
  | `display_name`        | `dn`      |                                                |
  | `length`              | `xl`      | size in bytes                                  |
  | `trackers`            | `tr`      |                                                |
  | `web_seeds`           | `ws`      | BEP-19 HTTP seeds                              |
  | `acceptable_sources`  | `as`      | URL to the file content                        |
  | `exact_sources`       | `xs`      | URL to the metainfo file                       |
  | `keywords`            | `kt`      | list of search words                           |
  | `select_only`         | `so`      | BEP-53 file indices: integers and `Range`s     |
  | `peers`               | `x.pe`    | `"host:port"` strings                          |

  Info-hashes are held as raw binaries - the form used by the wire
  protocol, trackers, and the DHT - and accepted in hex or RFC 3548
  base32 when parsing. Rendering normalizes them to lowercase hex.

  ## Strictness

  In keeping with the rest of Bento, parsing rejects malformed input
  with descriptive errors rather than guessing:

    * the `xt` parameter is required and must carry a well-formed
      `urn:btih:` (40 hex or 32 base32 characters) or `urn:btmh:`
      (a sha2-256 multihash) topic; other URN namespaces are errors,
    * repeated single-valued parameters (`xt` of the same version,
      `dn`, `xl`, `so`) are errors, as are out-of-range ports,
      unbracketed IPv6 peer addresses, malformed percent-encoding, and
      non-numeric lengths and indices,
    * integer parameters are limited to 20 digits, so adversarial input
      cannot force large big-integer conversions. The same bounds apply
      when rendering, so rendered URIs always parse back.

  Unknown parameters are ignored. Parameters with empty values are
  ignored. Numbered parameters (`tr.1`, `tr.2`, ...) are treated as
  their base parameter, in document order.
  """

  alias Bento.MagnetError
  alias Bento.OrderedDict

  @type select_item :: non_neg_integer() | Range.t()

  @type t :: %__MODULE__{
          info_hash: <<_::160>> | nil,
          info_hash_v2: <<_::256>> | nil,
          display_name: String.t() | nil,
          length: non_neg_integer() | nil,
          trackers: [String.t()],
          web_seeds: [String.t()],
          acceptable_sources: [String.t()],
          exact_sources: [String.t()],
          keywords: [String.t()],
          select_only: [select_item()],
          peers: [String.t()]
        }

  defstruct info_hash: nil,
            info_hash_v2: nil,
            display_name: nil,
            length: nil,
            trackers: [],
            web_seeds: [],
            acceptable_sources: [],
            exact_sources: [],
            keywords: [],
            select_only: [],
            peers: []

  # Bounds integer parameters (xl, so) when parsing and rendering, so
  # rendered URIs always parse back. 20 digits covers any 64-bit size.
  @max_integer_digits 20
  @max_integer_value Integer.pow(10, @max_integer_digits)

  @doc """
  Parse a magnet URI.

      iex> {:ok, magnet} = Bento.Magnet.parse("magnet:?xt=urn:btih:" <>
      ...>   "C12FE1C06BBA254A9DC9F519B335AA7C1367A88A&so=0,2,4-6")
      iex> magnet.select_only
      [0, 2, 4..6]

  Returns `{:error, %Bento.MagnetError{}}` on malformed input:

      iex> {:error, error} = Bento.Magnet.parse("magnet:?xt=urn:btih:tooshort")
      iex> error.message
      ~S(Invalid v1 info-hash, expected 40 hex or 32 base32 characters: "tooshort")
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, MagnetError.t()}
  def parse(uri) when is_binary(uri) do
    {:ok, parse!(uri)}
  rescue
    exception in [MagnetError] -> {:error, exception}
  end

  @doc """
  Parse a magnet URI, raising `Bento.MagnetError` on malformed input.

      iex> Bento.Magnet.parse!("magnet:?xt=urn:btih:" <>
      ...>   "c12fe1c06bba254a9dc9f519b335aa7c1367a88a").info_hash
      Base.decode16!("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", case: :lower)
  """
  @spec parse!(String.t()) :: t() | no_return()
  def parse!(uri) when is_binary(uri) do
    magnet =
      uri
      |> String.trim()
      |> query!()
      |> String.split("&")
      |> Enum.reduce(%__MODULE__{}, &put_pair(&2, &1))

    if magnet.info_hash == nil and magnet.info_hash_v2 == nil do
      raise MagnetError, message: "Missing exact topic: no xt=urn:btih: or xt=urn:btmh: parameter"
    end

    %{
      magnet
      | trackers: Enum.reverse(magnet.trackers),
        web_seeds: Enum.reverse(magnet.web_seeds),
        acceptable_sources: Enum.reverse(magnet.acceptable_sources),
        exact_sources: Enum.reverse(magnet.exact_sources),
        keywords: Enum.reverse(magnet.keywords),
        peers: Enum.reverse(magnet.peers)
    }
  end

  defp query!(uri) do
    case String.split(uri, "?", parts: 2) do
      [scheme, query] when byte_size(scheme) == 7 ->
        if String.downcase(scheme) == "magnet:" do
          # A raw "#" ends the query: fragments are not part of it.
          query |> String.split("#", parts: 2) |> hd()
        else
          raise MagnetError, message: "Not a magnet URI: #{bound(uri)}"
        end

      _ ->
        raise MagnetError, message: "Not a magnet URI: #{bound(uri)}"
    end
  end

  defp put_pair(magnet, pair) do
    case String.split(pair, "=", parts: 2) do
      # Bare tokens and empty values carry no information.
      [_key] ->
        magnet

      [_key, ""] ->
        magnet

      [key, value] ->
        key = key |> decode!(pair) |> strip_index()
        put_param(magnet, key, decode!(value, pair))
    end
  end

  defp decode!(component, pair) do
    case decode_component(component, <<>>) do
      :error ->
        raise MagnetError, message: "Malformed percent-encoding in parameter: #{bound(pair)}"

      decoded ->
        decoded
    end
  end

  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # www-form decoding: "+" is a space and "%" must start two hex digits.
  # Done by hand because `URI.decode_www_form/1` passes malformed escapes
  # through unchanged (and has changed behavior across Elixir versions),
  # while Bento rejects malformed input.
  defp decode_component(<<?%, hi, lo, rest::binary>>, acc) when is_hex(hi) and is_hex(lo) do
    decode_component(rest, <<acc::binary, hex_digit(hi) * 16 + hex_digit(lo)>>)
  end

  defp decode_component(<<?%, _rest::binary>>, _acc), do: :error

  defp decode_component(<<?+, rest::binary>>, acc),
    do: decode_component(rest, <<acc::binary, ?\s>>)

  defp decode_component(<<byte, rest::binary>>, acc),
    do: decode_component(rest, <<acc::binary, byte>>)

  defp decode_component(<<>>, acc), do: acc

  defp hex_digit(c) when c in ?0..?9, do: c - ?0
  defp hex_digit(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_digit(c) when c in ?A..?F, do: c - ?A + 10

  # Numbered parameters ("tr.1") count as their base parameter. The digit
  # requirement keeps dotted names like "x.pe" intact.
  defp strip_index(key) do
    case Regex.run(~r/^(.+)\.\d+\z/, key) do
      [_, base] -> base
      nil -> key
    end
  end

  defp put_param(magnet, "xt", value), do: put_topic(magnet, value)

  defp put_param(%{display_name: nil} = magnet, "dn", value),
    do: %{magnet | display_name: value}

  defp put_param(_magnet, "dn", _value), do: raise(MagnetError, message: duplicate("dn"))

  defp put_param(%{length: nil} = magnet, "xl", value),
    do: %{magnet | length: integer!(value, "Invalid exact length (xl)")}

  defp put_param(_magnet, "xl", _value), do: raise(MagnetError, message: duplicate("xl"))

  defp put_param(magnet, "tr", value), do: %{magnet | trackers: [value | magnet.trackers]}
  defp put_param(magnet, "ws", value), do: %{magnet | web_seeds: [value | magnet.web_seeds]}

  defp put_param(magnet, "as", value),
    do: %{magnet | acceptable_sources: [value | magnet.acceptable_sources]}

  defp put_param(magnet, "xs", value),
    do: %{magnet | exact_sources: [value | magnet.exact_sources]}

  defp put_param(magnet, "kt", value),
    do: %{magnet | keywords: Enum.reverse(String.split(value)) ++ magnet.keywords}

  defp put_param(%{select_only: []} = magnet, "so", value),
    do: %{magnet | select_only: select_only!(value)}

  defp put_param(_magnet, "so", _value), do: raise(MagnetError, message: duplicate("so"))

  defp put_param(magnet, "x.pe", value),
    do: %{magnet | peers: [peer!(value) | magnet.peers]}

  defp put_param(magnet, _unknown, _value), do: magnet

  defp put_topic(magnet, <<urn::binary-size(9), rest::binary>> = value) do
    case String.downcase(urn) do
      "urn:btih:" -> put_info_hash(magnet, btih!(rest))
      "urn:btmh:" -> put_info_hash_v2(magnet, btmh!(rest))
      _ -> raise MagnetError, message: unsupported_topic(value)
    end
  end

  defp put_topic(_magnet, value), do: raise(MagnetError, message: unsupported_topic(value))

  defp unsupported_topic(value),
    do: "Unsupported exact topic (xt), expected urn:btih: or urn:btmh: - got: #{bound(value)}"

  defp put_info_hash(%{info_hash: nil} = magnet, hash), do: %{magnet | info_hash: hash}

  defp put_info_hash(_magnet, _hash),
    do: raise(MagnetError, message: duplicate("xt (urn:btih)"))

  defp put_info_hash_v2(%{info_hash_v2: nil} = magnet, hash), do: %{magnet | info_hash_v2: hash}

  defp put_info_hash_v2(_magnet, _hash),
    do: raise(MagnetError, message: duplicate("xt (urn:btmh)"))

  defp btih!(string) when byte_size(string) == 40 do
    case Base.decode16(string, case: :mixed) do
      {:ok, hash} -> hash
      :error -> raise MagnetError, message: "Invalid v1 info-hash, bad hex: #{bound(string)}"
    end
  end

  defp btih!(string) when byte_size(string) == 32 do
    case Base.decode32(string, case: :mixed, padding: false) do
      {:ok, hash} -> hash
      :error -> raise MagnetError, message: "Invalid v1 info-hash, bad base32: #{bound(string)}"
    end
  end

  defp btih!(string) do
    raise MagnetError,
      message: "Invalid v1 info-hash, expected 40 hex or 32 base32 characters: #{bound(string)}"
  end

  # BEP-52: a multihash in hex. Only sha2-256 (code 0x12, length 0x20) is
  # defined for BitTorrent.
  defp btmh!(string) do
    case Base.decode16(string, case: :mixed) do
      {:ok, <<0x12, 0x20, hash::binary-size(32)>>} ->
        hash

      {:ok, _other} ->
        raise MagnetError,
          message: "Unsupported v2 info-hash, expected a sha2-256 multihash: #{bound(string)}"

      :error ->
        raise MagnetError, message: "Invalid v2 info-hash, bad hex: #{bound(string)}"
    end
  end

  # BEP-53: comma-separated indices and ranges, like "0,2,4-6".
  defp select_only!(value) do
    for item <- String.split(value, ","), do: select_item!(item, value)
  end

  defp select_item!(item, value) do
    case String.split(item, "-", parts: 2) do
      [index] ->
        integer!(index, "Invalid select-only (so) value", value)

      [first, last] ->
        first = integer!(first, "Invalid select-only (so) value", value)
        last = integer!(last, "Invalid select-only (so) value", value)

        if first > last do
          raise MagnetError, message: "Invalid select-only (so) range: #{bound(value)}"
        end

        first..last
    end
  end

  defp peer!(value) do
    with [host, port] <- split_host_port(value),
         true <- valid_peer_host?(host),
         port when port in 1..65_535 <- port_number(port) do
      value
    else
      _ -> raise MagnetError, message: "Invalid peer address (x.pe): #{bound(value)}"
    end
  end

  # BEP-9 hosts: a hostname or IPv4 literal (no colons), or a bracketed
  # IPv6 literal - unbracketed IPv6 would be ambiguous with the port.
  defp valid_peer_host?(host) do
    Regex.match?(~r/^\[[^\[\]]+\]\z/, host) or
      (host != "" and not String.contains?(host, ["[", "]", ":"]))
  end

  # The port comes after the last colon: "host:port", "ipv4:port" or
  # "[ipv6]:port" (BEP-9).
  defp split_host_port(value) do
    case :binary.matches(value, ":") do
      [] ->
        :error

      matches ->
        {pos, 1} = List.last(matches)
        host = binary_part(value, 0, pos)
        port = binary_part(value, pos + 1, byte_size(value) - pos - 1)
        [host, port]
    end
  end

  # Note `\z`, not `$`: the latter would also match just before a trailing
  # newline, letting values like "42\n" through to `String.to_integer/1`.
  defp port_number(string) do
    if string =~ ~r/^\d{1,5}\z/, do: String.to_integer(string), else: :error
  end

  defp integer!(value, error), do: integer!(value, error, value)

  defp integer!(value, error, context) do
    if byte_size(value) <= @max_integer_digits and value =~ ~r/^\d+\z/ do
      String.to_integer(value)
    else
      raise MagnetError, message: "#{error}: #{bound(context)}"
    end
  end

  defp duplicate(param), do: "Duplicate parameter: #{param}"

  # Bounds inspected values in error messages: non-printable binaries
  # render one byte per element, so :limit must stay small, and inspect
  # does not bound integer digits at all.
  defp bound(value) when is_integer(value) do
    digits = Integer.to_string(value)

    if byte_size(digits) > 32 do
      binary_part(digits, 0, 32) <> "..."
    else
      digits
    end
  end

  defp bound(value), do: inspect(value, printable_limit: 32, limit: 8)

  @doc """
  Render a magnet URI, raising `Bento.MagnetError` if the struct holds
  no info-hash or otherwise invalid values.

  Info-hashes are emitted as lowercase hex, values are percent-encoded,
  and empty values are omitted. Also available through the
  `String.Chars` protocol, so magnet structs work in string
  interpolation.

      iex> magnet = %Bento.Magnet{
      ...>   info_hash: Base.decode16!("C12FE1C06BBA254A9DC9F519B335AA7C1367A88A"),
      ...>   display_name: "Example File",
      ...>   trackers: ["udp://tracker.example.com:80"]
      ...> }
      iex> Bento.Magnet.to_string(magnet)
      "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=Example+File&tr=udp%3A%2F%2Ftracker.example.com%3A80"
  """
  @spec to_string(t()) :: String.t() | no_return()
  def to_string(%__MODULE__{} = magnet) do
    params =
      [
        topic_params(magnet),
        scalar_param("dn", magnet.display_name),
        length_param(magnet.length),
        list_params("tr", magnet.trackers, "trackers"),
        list_params("ws", magnet.web_seeds, "web_seeds"),
        list_params("as", magnet.acceptable_sources, "acceptable_sources"),
        list_params("xs", magnet.exact_sources, "exact_sources"),
        keywords_param(magnet.keywords),
        select_only_param(magnet.select_only),
        peer_params(magnet.peers)
      ]
      |> Enum.concat()

    "magnet:?" <> Enum.join(params, "&")
  end

  defp topic_params(%{info_hash: nil, info_hash_v2: nil}) do
    raise MagnetError, message: "Cannot render a magnet URI without an info-hash"
  end

  defp topic_params(%{info_hash: v1, info_hash_v2: v2}) do
    btih =
      case v1 do
        nil -> []
        <<_::160>> -> ["xt=urn:btih:" <> Base.encode16(v1, case: :lower)]
        _other -> raise MagnetError, message: "info_hash must be a 20-byte binary"
      end

    btmh =
      case v2 do
        nil -> []
        <<_::256>> -> ["xt=urn:btmh:1220" <> Base.encode16(v2, case: :lower)]
        _other -> raise MagnetError, message: "info_hash_v2 must be a 32-byte binary"
      end

    btih ++ btmh
  end

  defp scalar_param(_key, nil), do: []
  defp scalar_param(_key, ""), do: []

  defp scalar_param(key, value) when is_binary(value),
    do: [key <> "=" <> URI.encode_www_form(value)]

  defp scalar_param(key, value),
    do: raise(MagnetError, message: "#{key} must be a string, got: #{bound(value)}")

  defp length_param(nil), do: []

  defp length_param(length)
       when is_integer(length) and length >= 0 and length < @max_integer_value,
       do: ["xl=#{length}"]

  defp length_param(length) do
    raise MagnetError,
      message:
        "length must be a non-negative integer of at most " <>
          "#{@max_integer_digits} digits, got: #{bound(length)}"
  end

  defp list_params(key, values, field) when is_list(values) do
    Enum.flat_map(values, fn
      "" -> []
      value when is_binary(value) -> [key <> "=" <> URI.encode_www_form(value)]
      value -> raise MagnetError, message: "#{field} must be strings, got: #{bound(value)}"
    end)
  end

  defp list_params(_key, values, field),
    do: raise(MagnetError, message: "#{field} must be a list, got: #{bound(values)}")

  defp keywords_param([]), do: []

  defp keywords_param(keywords) when is_list(keywords) do
    words =
      Enum.map(keywords, fn
        word when is_binary(word) and word != "" ->
          if word =~ ~r/\s/ do
            raise MagnetError, message: "keywords must not contain whitespace: #{bound(word)}"
          end

          word

        word ->
          raise MagnetError, message: "keywords must be non-empty strings, got: #{bound(word)}"
      end)

    ["kt=" <> URI.encode_www_form(Enum.join(words, " "))]
  end

  defp keywords_param(keywords),
    do: raise(MagnetError, message: "keywords must be a list, got: #{bound(keywords)}")

  defp select_only_param([]), do: []

  defp select_only_param(items) when is_list(items) do
    # Digits, commas and dashes are query-safe; emitted raw, as BEP-53 shows.
    ["so=" <> Enum.map_join(items, ",", &select_item_string/1)]
  end

  defp select_only_param(items),
    do: raise(MagnetError, message: "select_only must be a list, got: #{bound(items)}")

  defp select_item_string(index)
       when is_integer(index) and index >= 0 and index < @max_integer_value,
       do: Integer.to_string(index)

  defp select_item_string(first..last//1 = _range)
       when first >= 0 and first <= last and last < @max_integer_value,
       do: "#{first}-#{last}"

  defp select_item_string(item) do
    raise MagnetError,
      message:
        "select_only items must be non-negative integers or ascending ranges " <>
          "of at most #{@max_integer_digits} digits, got: #{bound(item)}"
  end

  defp peer_params(peers) when is_list(peers) do
    # Colons and brackets are conventionally left raw in x.pe values.
    # peer!/1 enforces the BEP-9 host:port form, so rendered URIs always
    # parse back.
    Enum.flat_map(peers, fn
      "" -> []
      peer when is_binary(peer) -> ["x.pe=" <> URI.encode(peer!(peer), &peer_char?/1)]
      peer -> raise MagnetError, message: "peers must be strings, got: #{bound(peer)}"
    end)
  end

  defp peer_params(peers),
    do: raise(MagnetError, message: "peers must be a list, got: #{bound(peers)}")

  defp peer_char?(char), do: char in ~c"[]:" or URI.char_unreserved?(char)

  @doc """
  Build a magnet link from the raw bytes of a torrent metainfo file.

  The info-hash is computed over the **exact bytes** of the file's info
  dictionary (decoded with `dicts: :ordered` and re-encoded
  byte-for-byte), so it matches the hash other BitTorrent clients
  compute even for non-canonical files. This is also why the function
  takes the file's bytes rather than a decoded `Bento.Metainfo.Torrent`
  struct: re-encoding a struct that dropped unknown keys would produce
  the wrong hash.

  v1 torrents get an `info_hash`, v2 (BEP-52) torrents an
  `info_hash_v2`, and hybrid torrents both. The display name, length,
  trackers (`announce-list` falling back to `announce`), and web seeds
  (`url-list`) are carried over when present.

      iex> data = Bento.encode!(%{
      ...>   "announce" => "http://tracker.example.com/announce",
      ...>   "info" => %{"name" => "example.txt", "length" => 42,
      ...>               "piece length" => 16384, "pieces" => <<0::160>>}
      ...> })
      iex> {:ok, magnet} = Bento.Magnet.from_torrent(data)
      iex> "\#{magnet}"
      "magnet:?xt=urn:btih:d09849a439468af225a96acec4e10d208329ac6e" <>
        "&dn=example.txt&xl=42&tr=http%3A%2F%2Ftracker.example.com%2Fannounce"

  Returns `{:error, %Bento.SyntaxError{}}` when the input isn't valid
  Bencoding, and `{:error, %Bento.MagnetError{}}` when it is not a
  torrent metainfo dictionary.
  """
  @spec from_torrent(iodata()) :: {:ok, t()} | failure
        when failure: {:error, MagnetError.t() | Bento.SyntaxError.t()}
  def from_torrent(iodata) do
    with {:ok, meta} <- Bento.decode(iodata, dicts: :ordered),
         {:ok, info} <- fetch_info(meta) do
      build_magnet(meta, info)
    end
  end

  @doc """
  Like `from_torrent/1`, but raises on error.

      iex> File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
      ...> |> Bento.Magnet.from_torrent!()
      ...> |> Map.get(:display_name)
      "ubuntu-14.04.4-desktop-amd64.iso"
  """
  @spec from_torrent!(iodata()) :: t() | no_return()
  def from_torrent!(iodata) do
    case from_torrent(iodata) do
      {:ok, magnet} -> magnet
      {:error, error} -> raise error
    end
  end

  defp fetch_info(%OrderedDict{} = meta) do
    # With duplicate "info" keys the hash would be ambiguous: clients
    # hashing the raw bytes could disagree on which dictionary they named.
    case Enum.count(meta, fn {key, _} -> key == "info" end) do
      1 ->
        case OrderedDict.fetch(meta, "info") do
          {:ok, %OrderedDict{} = info} -> {:ok, info}
          {:ok, _other} -> invalid_metainfo("info is not a dictionary")
        end

      0 ->
        invalid_metainfo("missing info dictionary")

      _ ->
        invalid_metainfo("duplicate info dictionary")
    end
  end

  defp fetch_info(_other), do: invalid_metainfo("not a dictionary")

  defp invalid_metainfo(reason) do
    {:error, %MagnetError{message: "Invalid metainfo file: #{reason}"}}
  end

  defp build_magnet(meta, info) do
    info_bytes = Bento.encode!(info)
    v1? = match?({:ok, _}, OrderedDict.fetch(info, "pieces"))
    v2? = OrderedDict.fetch(info, "meta version") == {:ok, 2}

    if v1? or v2? do
      {:ok,
       %__MODULE__{
         info_hash: if(v1?, do: :crypto.hash(:sha, info_bytes)),
         info_hash_v2: if(v2?, do: :crypto.hash(:sha256, info_bytes)),
         display_name: display_name(info),
         length: total_length(info),
         trackers: trackers(meta),
         web_seeds: web_seeds(meta)
       }}
    else
      invalid_metainfo("missing info.pieces or info.\"meta version\"")
    end
  end

  defp display_name(info) do
    case {OrderedDict.fetch(info, "name.utf-8"), OrderedDict.fetch(info, "name")} do
      {{:ok, name}, _} when is_binary(name) and name != "" -> name
      {_, {:ok, name}} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp total_length(info) do
    with :error <- single_file_length(info),
         :error <- multi_file_length(info),
         :error <- file_tree_length(info) do
      nil
    else
      # Lengths past the rendering bound are dropped: xl is auxiliary,
      # and the struct must stay renderable.
      {:ok, length} when length < @max_integer_value -> length
      {:ok, _absurd} -> nil
    end
  end

  defp single_file_length(info) do
    case OrderedDict.fetch(info, "length") do
      {:ok, length} when is_integer(length) and length >= 0 -> {:ok, length}
      _ -> :error
    end
  end

  defp multi_file_length(info) do
    case OrderedDict.fetch(info, "files") do
      {:ok, files} when is_list(files) -> total_file_lengths(files)
      _ -> :error
    end
  end

  defp total_file_lengths(files) do
    Enum.reduce_while(files, {:ok, 0}, fn
      %OrderedDict{} = file, {:ok, total} -> add_file_length(file, total)
      _other, _acc -> {:halt, :error}
    end)
  end

  defp add_file_length(file, total) do
    case single_file_length(file) do
      {:ok, length} -> {:cont, {:ok, total + length}}
      :error -> {:halt, :error}
    end
  end

  # BEP-52 file tree: a file is a `""` key holding its attributes, any
  # other key is a directory holding a subtree.
  defp file_tree_length(info) do
    case OrderedDict.fetch(info, "file tree") do
      {:ok, %OrderedDict{} = tree} -> tree_length(tree)
      _ -> :error
    end
  end

  defp tree_length(%OrderedDict{} = node) do
    Enum.reduce_while(node, {:ok, 0}, fn
      {"", %OrderedDict{} = file}, {:ok, total} ->
        add_file_length(file, total)

      {_name, %OrderedDict{} = child}, {:ok, total} ->
        add_tree_length(child, total)

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp add_tree_length(child, total) do
    case tree_length(child) do
      {:ok, length} -> {:cont, {:ok, total + length}}
      :error -> {:halt, :error}
    end
  end

  defp trackers(meta) do
    announce_list =
      case OrderedDict.fetch(meta, "announce-list") do
        {:ok, tiers} when is_list(tiers) ->
          tiers
          |> Enum.flat_map(fn
            tier when is_list(tier) -> Enum.filter(tier, &(is_binary(&1) and &1 != ""))
            _other -> []
          end)
          |> Enum.uniq()

        _ ->
          []
      end

    case {announce_list, OrderedDict.fetch(meta, "announce")} do
      {[_ | _], _} ->
        announce_list

      {[], {:ok, announce}} when is_binary(announce) and announce != "" ->
        [announce]

      _ ->
        []
    end
  end

  # BEP-19: top-level "url-list", a single URL or a list of them.
  defp web_seeds(meta) do
    case OrderedDict.fetch(meta, "url-list") do
      {:ok, url} when is_binary(url) and url != "" -> [url]
      {:ok, urls} when is_list(urls) -> Enum.filter(urls, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end
end

defimpl String.Chars, for: Bento.Magnet do
  def to_string(magnet), do: Bento.Magnet.to_string(magnet)
end
