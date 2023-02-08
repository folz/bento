defmodule Bento.SyntaxError do
  @moduledoc """
  Raised when parsing a binary that isn't valid according to BEP-3.
  """

  defexception [:message, :token]

  def exception(opts) do
    token = opts[:token]

    message =
      if token do
        "Unexpected token #{token}"
      else
        "Unexpected end of input"
      end

    %Bento.SyntaxError{message: message, token: token}
  end
end

defmodule Bento.Parser do
  @moduledoc """
  A BEP-3 conforming Bencoding parser.

  See: http://bittorrent.org/beps/bep_0003.html and
       https://wiki.theory.org/BitTorrentSpecification#Bencoding
  """

  alias Bento.SyntaxError

  @type t :: integer() | String.t() | list() | map()
  @type parse_err :: :invalid | {:invalid, String.t()}

  @spec parse(iodata()) :: {:ok, t()} | {:error, parse_err()}
  def parse(iodata) do
    {value, rest} = iodata |> IO.iodata_to_binary() |> parse_value()

    case rest do
      "" -> {:ok, value}
      other -> syntax_error(other)
    end
  catch
    :invalid -> {:error, :invalid}
    {:invalid, token} -> {:error, {:invalid, token}}
  end

  @spec parse!(iodata()) :: t() | no_return()
  def parse!(iodata) do
    case parse(iodata) do
      {:ok, value} -> value
      {:error, :invalid} -> raise SyntaxError
      {:error, {:invalid, token}} -> raise SyntaxError, token: token
    end
  end

  # Bencode entry points
  defp parse_value("d" <> rest), do: map_pairs(rest, [])
  defp parse_value("l" <> rest), do: list_values(rest, [])

  defp parse_value(<<c>> <> _ = str) when c in '0123456789' do
    string_start(str)
  end

  defp parse_value("i" <> rest), do: integer_start(rest)

  # No other valid cases when starting to parse a bencoded string
  defp parse_value(other), do: syntax_error(other)

  ## Integers

  defp integer_start("0e" <> rest), do: {0, rest}

  # Error cases
  defp integer_start("-e" <> _), do: syntax_error("i-e")
  defp integer_start("-0" <> _), do: syntax_error("i-0#e")

  # Integer parsing
  defp integer_start(<<char>> <> rest) when char in '-123456789' do
    integer_continue(rest, [char])
  end

  defp integer_start(other), do: syntax_error(other)

  defp integer_continue("e" <> rest, acc) do
    {acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer(), rest}
  end

  defp integer_continue(<<digit>> <> rest, acc) when digit in '0123456789' do
    integer_continue(rest, [digit | acc])
  end

  defp integer_continue(other, _acc), do: syntax_error(other)

  ## Strings

  defp string_start("0:" <> rest), do: {"", rest}

  defp string_start(<<digit>> <> rest) when digit in '123456789' do
    string_length(rest, [digit])
  end

  defp string_start(other), do: syntax_error(other)

  defp string_length(<<digit>> <> rest, acc) when digit in '0123456789' do
    string_length(rest, [digit | acc])
  end

  defp string_length(":" <> rest, acc) do
    string_contents(acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer(), rest)
  end

  defp string_length(other, _acc), do: syntax_error(other)

  defp string_contents(len, str) when len > byte_size(str) do
    syntax_error("#{len} > #{byte_size(str)} for #{str}")
  end

  defp string_contents(len, str) do
    <<contents::binary-size(len)>> <> rest = str
    {contents, rest}
  end

  ## Lists

  defp list_values("e" <> rest, []), do: {[], rest}

  defp list_values(str, acc) do
    {value, rest} = parse_value(str)

    acc = [value | acc]

    case rest do
      "e" <> rest -> {acc |> Enum.reverse(), rest}
      "" -> syntax_error()
      rest -> list_values(rest, acc)
    end
  end

  ## Maps

  defp map_pairs("e" <> rest, []), do: {%{}, rest}

  defp map_pairs(str, acc) do
    {name, rest} = string_start(str)
    {value, rest} = parse_value(rest)

    acc = [{name, value} | acc]

    case rest do
      "e" <> rest -> {acc |> Map.new(), rest}
      "" -> syntax_error()
      rest -> map_pairs(rest, acc)
    end
  end

  ## Errors

  defp syntax_error(token), do: throw({:invalid, token})
  defp syntax_error(), do: throw(:invalid)
end
