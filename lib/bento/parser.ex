defmodule Bento.SyntaxError do
  @moduledoc """
  Raised when parsing input that isn't valid Bencoding according to BEP-3.

  The exception carries the byte `position` of the offending input, the
  offending `token` (when one is available), and the original `data`, so
  errors can be located precisely. Messages stay small even when the
  input is large.
  """

  @type t :: %__MODULE__{
          message: String.t() | nil,
          token: binary() | nil,
          position: non_neg_integer() | nil,
          data: binary() | nil
        }

  defexception [:message, :token, :position, :data]

  def message(%{message: message}) when is_binary(message), do: message

  def message(%{token: token, position: position}) when is_binary(token) do
    "unexpected sequence at position #{position || 0}: #{inspect_bounded(token)}"
  end

  def message(%{position: position, data: data})
      when is_integer(position) and is_binary(data) and position >= byte_size(data) do
    "unexpected end of input at position #{position}"
  end

  def message(%{position: position, data: data})
      when is_integer(position) and is_binary(data) do
    byte = :binary.at(data, position)

    if String.printable?(<<byte>>) do
      "unexpected byte at position #{position}: " <>
        "#{inspect(byte, base: :hex)} (#{inspect(<<byte>>)})"
    else
      "unexpected byte at position #{position}: #{inspect(byte, base: :hex)}"
    end
  end

  def message(_), do: "unexpected end of input"

  defp inspect_bounded(token) do
    inspect(token, printable_limit: 32, limit: 32)
  end
end

defmodule Bento.Parser do
  @moduledoc """
  A BEP-3 conforming Bencoding parser.

  The parser is written as a single tail-recursive state machine over the
  input binary. Containers are tracked on an explicit stack instead of
  the call stack, the input is scanned by byte offset so strings are
  extracted with a single sub-binary slice, and decoding options are
  resolved into functions once, before parsing starts.

  ## Options

    * `:keys` - controls how dictionary keys are decoded:

      * `:strings` (default) - keys are returned as binary strings,
      * `:atoms` - keys are converted with `String.to_atom/1`,
      * `:atoms!` - keys are converted with `String.to_existing_atom/1`,
      * a function accepting a string and returning the key.

      Note `:atoms` creates atoms at runtime. Since atoms are not
      garbage-collected, this can be a denial-of-service vector when
      decoding untrusted data.

    * `:strings` - controls how strings (including keys) are decoded:

      * `:reference` (default) - returns sub-binaries into the input
        binary whenever possible, avoiding copies,
      * `:copy` - copies every string. Useful when decoded values
        outlive the input (for example when stored in ETS or a
        long-lived process), as a referenced sub-binary keeps the whole
        input binary alive.

    * `:dicts` - controls how dictionaries are decoded:

      * `:strict` (default) - dictionaries become maps; keys must be
        unique and in canonical (byte-wise ascending) order, as BEP-3
        mandates, so decode/encode round-trips are byte-identical.
        Out-of-order and duplicate keys are syntax errors naming the
        offending key,
      * `:lenient` - like `:strict` but without the key ordering and
        uniqueness checks, for reading non-conforming files produced by
        sloppy encoders. The first occurrence of a duplicated key wins,
      * `:ordered` - dictionaries become `Bento.OrderedDict` structs
        preserving the exact wire order of entries (no checks), so even
        non-canonical input can be re-encoded byte-for-byte.

  Decoded integers are limited to
  `Application.get_env(:bento, :decoding_integer_digit_limit, 1024)`
  digits to avoid excessive big-integer conversion cost on adversarial
  input.

  See:

  - http://www.bittorrent.org/beps/bep_0003.html#bencoding
  - https://wiki.theory.org/BitTorrentSpecification#Bencoding
  """

  alias Bento.SyntaxError

  import Record, only: [defrecordp: 2]

  @type t :: integer() | String.t() | list() | map() | Bento.OrderedDict.t()
  @type opts :: [
          keys: :strings | :atoms | :atoms! | (String.t() -> term()),
          strings: :reference | :copy,
          dicts: :strict | :lenient | :ordered
        ]
  @type parse_err :: SyntaxError.t()

  # Continuation tags kept on the parser stack. Integers (rather than
  # atoms) let the VM dispatch on them with a jump table.
  @terminate 0
  @list 1
  @dict_key 2
  @dict_value 3
  @prefix 4

  defrecordp :decode, keys: nil, strings: nil, dicts: nil

  @integer_digit_limit Application.compile_env(:bento, :decoding_integer_digit_limit, 1024)

  # Upper bound while accumulating string lengths; keeps the accumulator
  # a small integer and rejects absurd lengths before slicing.
  @string_length_limit 1_000_000_000_000_000

  @doc """
  Parse a complete Bencoded value.

      iex> Bento.Parser.parse("i42e")
      {:ok, 42}

      iex> Bento.Parser.parse("4:spam")
      {:ok, "spam"}
  """
  @spec parse(iodata(), opts()) :: {:ok, t()} | {:error, parse_err()}
  def parse(iodata, opts \\ []) do
    data = IO.iodata_to_binary(iodata)
    decode = build_decode(opts)

    try do
      {:ok, value(data, data, 0, [@terminate], decode)}
    catch
      {:position, position} ->
        {:error, %SyntaxError{position: position, data: data}}

      {:token, token, position} ->
        {:error, %SyntaxError{token: token, position: position, data: data}}
    end
  end

  @doc """
  Parse a complete Bencoded value, raising `Bento.SyntaxError` on error.

      iex> Bento.Parser.parse!("l4:spam4:eggse")
      ["spam", "eggs"]
  """
  @spec parse!(iodata(), opts()) :: t() | no_return()
  def parse!(iodata, opts \\ []) do
    case parse(iodata, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc """
  Parse a single Bencoded value off the front of the input, returning the
  remaining bytes as well.

  Useful for streams that carry several consecutive Bencoded values.

      iex> Bento.Parser.parse_prefix("i1ei2e")
      {:ok, 1, "i2e"}
  """
  @spec parse_prefix(iodata(), opts()) :: {:ok, t(), binary()} | {:error, parse_err()}
  def parse_prefix(iodata, opts \\ []) do
    data = IO.iodata_to_binary(iodata)
    decode = build_decode(opts)

    try do
      value(data, data, 0, [@prefix], decode)
    catch
      {:position, position} ->
        {:error, %SyntaxError{position: position, data: data}}

      {:token, token, position} ->
        {:error, %SyntaxError{token: token, position: position, data: data}}
    else
      {value, rest} -> {:ok, value, rest}
    end
  end

  ## Option handling

  defp build_decode(opts) do
    keys = Keyword.get(opts, :keys, :strings)
    strings = Keyword.get(opts, :strings, :reference)
    dicts = Keyword.get(opts, :dicts, :strict)

    decode(keys: key_fun(keys), strings: string_fun(strings), dicts: dict_mode(dicts))
  end

  defp key_fun(:strings), do: & &1
  defp key_fun(:atoms), do: &String.to_atom/1
  defp key_fun(:atoms!), do: &String.to_existing_atom/1
  defp key_fun(fun) when is_function(fun, 1), do: fun

  defp key_fun(other) do
    raise ArgumentError, "invalid value for the `:keys` option: #{inspect(other)}"
  end

  defp string_fun(:reference), do: & &1
  defp string_fun(:copy), do: &:binary.copy/1

  defp string_fun(other) do
    raise ArgumentError, "invalid value for the `:strings` option: #{inspect(other)}"
  end

  defp dict_mode(mode) when mode in [:strict, :lenient, :ordered], do: mode

  defp dict_mode(other) do
    raise ArgumentError, "invalid value for the `:dicts` option: #{inspect(other)}"
  end

  ## Value dispatch

  defp value(<<?i, rest::bits>>, original, skip, stack, decode) do
    integer(rest, original, skip + 1, stack, decode)
  end

  defp value(<<?l, rest::bits>>, original, skip, stack, decode) do
    value(rest, original, skip + 1, [@list, [] | stack], decode)
  end

  defp value(<<?d, rest::bits>>, original, skip, stack, decode) do
    dict_key(rest, original, skip + 1, [nil, [] | stack], decode)
  end

  defp value(<<?0, rest::bits>>, original, skip, stack, decode) do
    string_zero(rest, original, skip, stack, decode)
  end

  defp value(<<byte, rest::bits>>, original, skip, stack, decode) when byte in ?1..?9 do
    string_len(rest, original, skip + 1, stack, decode, byte - ?0)
  end

  defp value(<<?e, rest::bits>>, original, skip, stack, decode) do
    # Only valid as the immediate end of an empty list; a dictionary's
    # end is handled by dict_key/5 and a non-empty list's by list_cont/6.
    case stack do
      [@list, [] | stack] -> continue(rest, original, skip + 1, stack, decode, [])
      _ -> error(original, skip)
    end
  end

  defp value(<<_byte, _rest::bits>>, original, skip, _stack, _decode) do
    error(original, skip)
  end

  defp value(<<>>, original, skip, _stack, _decode) do
    empty_error(original, skip)
  end

  ## Integers

  defp integer(<<?-, rest::bits>>, original, skip, stack, decode) do
    integer_negative(rest, original, skip, stack, decode)
  end

  defp integer(<<?0, rest::bits>>, original, skip, stack, decode) do
    integer_zero(rest, original, skip, stack, decode)
  end

  defp integer(<<byte, rest::bits>>, original, skip, stack, decode) when byte in ?1..?9 do
    integer_digits(rest, original, skip, stack, decode, 1)
  end

  defp integer(<<_byte, _rest::bits>>, original, skip, _stack, _decode) do
    error(original, skip)
  end

  defp integer(<<>>, original, skip, _stack, _decode) do
    empty_error(original, skip)
  end

  # "i-0e" and "i-e" are invalid: after a minus sign only 1-9 may follow.
  defp integer_negative(<<byte, rest::bits>>, original, skip, stack, decode)
       when byte in ?1..?9 do
    integer_digits(rest, original, skip, stack, decode, 2)
  end

  defp integer_negative(<<_byte, _rest::bits>>, original, skip, _stack, _decode) do
    error(original, skip + 1)
  end

  defp integer_negative(<<>>, original, skip, _stack, _decode) do
    empty_error(original, skip + 1)
  end

  # "i0e" is the only valid integer starting with a zero.
  defp integer_zero(<<?e, rest::bits>>, original, skip, stack, decode) do
    continue(rest, original, skip + 2, stack, decode, 0)
  end

  defp integer_zero(<<_byte, _rest::bits>>, original, skip, _stack, _decode) do
    error(original, skip + 1)
  end

  defp integer_zero(<<>>, original, skip, _stack, _decode) do
    empty_error(original, skip + 1)
  end

  defp integer_digits(<<byte, rest::bits>>, original, skip, stack, decode, len)
       when byte in ?0..?9 do
    integer_digits(rest, original, skip, stack, decode, len + 1)
  end

  defp integer_digits(<<?e, rest::bits>>, original, skip, stack, decode, len) do
    if len > @integer_digit_limit do
      token_error(original, skip, len)
    end

    int = String.to_integer(binary_part(original, skip, len))
    continue(rest, original, skip + len + 1, stack, decode, int)
  end

  defp integer_digits(<<_byte, _rest::bits>>, original, skip, _stack, _decode, len) do
    error(original, skip + len)
  end

  defp integer_digits(<<>>, original, skip, _stack, _decode, len) do
    empty_error(original, skip + len)
  end

  ## Strings

  # A string length starting with ?0 must be exactly "0:" - lengths have
  # no leading zeros.
  defp string_zero(<<?:, rest::bits>>, original, skip, stack, decode) do
    continue(rest, original, skip + 2, stack, decode, "")
  end

  defp string_zero(<<_byte, _rest::bits>>, original, skip, _stack, _decode) do
    error(original, skip + 1)
  end

  defp string_zero(<<>>, original, skip, _stack, _decode) do
    empty_error(original, skip + 1)
  end

  defp string_len(<<byte, rest::bits>>, original, skip, stack, decode, len)
       when byte in ?0..?9 and len < @string_length_limit do
    string_len(rest, original, skip + 1, stack, decode, len * 10 + (byte - ?0))
  end

  defp string_len(<<?:, rest::bits>>, original, skip, stack, decode, len) do
    string_content(rest, original, skip + 1, stack, decode, len)
  end

  defp string_len(<<_byte, _rest::bits>>, original, skip, _stack, _decode, _len) do
    error(original, skip)
  end

  defp string_len(<<>>, original, skip, _stack, _decode, _len) do
    empty_error(original, skip)
  end

  defp string_content(data, original, skip, stack, decode, len) do
    case data do
      <<_::binary-size(^len), rest::bits>> ->
        decode(strings: string_fun) = decode
        string = string_fun.(binary_part(original, skip, len))
        continue(rest, original, skip + len, stack, decode, string)

      _ ->
        # The declared length overruns the input.
        empty_error(original, byte_size(original))
    end
  end

  ## Lists

  defp list_cont(<<?e, rest::bits>>, original, skip, [acc | stack], decode, value) do
    continue(rest, original, skip + 1, stack, decode, :lists.reverse([value | acc]))
  end

  defp list_cont(<<>>, original, skip, _stack, _decode, _value) do
    empty_error(original, skip)
  end

  defp list_cont(data, original, skip, [acc | stack], decode, value) do
    value(data, original, skip, [@list, [value | acc] | stack], decode)
  end

  ## Dictionaries
  #
  # An in-flight dictionary occupies two stack slots: the previous raw
  # key (`nil` before the first entry, used for the :strict order and
  # uniqueness check) and the accumulated entries in reverse wire order.

  defp dict_key(<<?e, rest::bits>>, original, skip, [_prev, acc | stack], decode) do
    decode(dicts: dicts) = decode
    continue(rest, original, skip + 1, stack, decode, finish_dict(dicts, acc))
  end

  defp dict_key(<<?0, rest::bits>>, original, skip, stack, decode) do
    string_zero(rest, original, skip, [@dict_key | stack], decode)
  end

  defp dict_key(<<byte, rest::bits>>, original, skip, stack, decode) when byte in ?1..?9 do
    string_len(rest, original, skip + 1, [@dict_key | stack], decode, byte - ?0)
  end

  defp dict_key(<<_byte, _rest::bits>>, original, skip, _stack, _decode) do
    error(original, skip)
  end

  defp dict_key(<<>>, original, skip, _stack, _decode) do
    empty_error(original, skip)
  end

  defp dict_pair(<<data::bits>>, original, skip, [prev, acc | stack], decode, key) do
    decode(dicts: dicts, keys: key_fun) = decode
    verify_key(dicts, prev, key, skip)
    value(data, original, skip, [@dict_value, key_fun.(key), key, acc | stack], decode)
  end

  # BEP-3 requires keys to be unique and in byte-wise ascending order,
  # comparing raw strings. Entries arrive in wire order, so comparing
  # against the previous raw key suffices.
  defp verify_key(:strict, prev, key, skip) when is_binary(prev) and prev >= key do
    size = byte_size(key)
    token = if size > 32, do: binary_part(key, 0, 32), else: key
    throw({:token, token, skip - size})
  end

  defp verify_key(_dicts, _prev, _key, _skip), do: :ok

  defp dict_commit(<<data::bits>>, original, skip, [key, raw, acc | stack], decode, value) do
    dict_key(data, original, skip, [raw, [{key, value} | acc] | stack], decode)
  end

  # The pair list is in reverse wire order, so with duplicated keys (only
  # possible in :lenient mode) :maps.from_list/1 keeps the first
  # occurrence, like previous Bento versions did.
  defp finish_dict(:ordered, acc), do: Bento.OrderedDict.new(:lists.reverse(acc))
  defp finish_dict(_strict_or_lenient, acc), do: :maps.from_list(acc)

  ## Continuations

  @compile {:inline, continue: 6}

  defp continue(rest, original, skip, stack, decode, value) do
    case stack do
      [@terminate | stack] -> terminate(rest, original, skip, stack, decode, value)
      [@list | stack] -> list_cont(rest, original, skip, stack, decode, value)
      [@dict_key | stack] -> dict_pair(rest, original, skip, stack, decode, value)
      [@dict_value | stack] -> dict_commit(rest, original, skip, stack, decode, value)
      [@prefix | stack] -> terminate_prefix(rest, original, skip, stack, decode, value)
    end
  end

  defp terminate(<<>>, _original, _skip, _stack, _decode, value), do: value

  defp terminate(<<_rest::bits>>, original, skip, _stack, _decode, _value) do
    error(original, skip)
  end

  defp terminate_prefix(<<_rest::bits>>, original, skip, _stack, _decode, value) do
    {value, binary_part(original, skip, byte_size(original) - skip)}
  end

  ## Errors

  @compile {:inline, error: 2, empty_error: 2}

  defp error(_original, skip), do: throw({:position, skip})

  defp empty_error(_original, skip), do: throw({:position, skip})

  defp token_error(original, skip, len) do
    throw({:token, binary_part(original, skip, min(len, 32)), skip})
  end
end
