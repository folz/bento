defmodule Bento.SyntaxError do
  defexception [:message, :token]

  def exception(opts) do
    message = if token = opts[:token] do
      "Unexpected token #{token}"
    else
      "Unexpected end of input"
    end

    %Bento.SyntaxError{message: message, token: token}
  end
end

defmodule Bento.Parser do
  @moduledoc ~S"""
  A BEP-3 conforming Bencoding parser.

  See: http://bittorrent.org/beps/bep_0003.html and
       https://wiki.theory.org/BitTorrentSpecification#Bencoding
  """

  use Bitwise

  alias Bento.SyntaxError

  @type t :: integer | String.t | list | map

  @spec parse(iodata) :: {:ok, t} | {:error, :invalid}
    | {:error, {:invalid, String.t}}
  def parse(iodata) do
    str = IO.iodata_to_binary(iodata)
    {value, rest} = value(str)
    case rest do
      "" -> {:ok, value}
      other -> syntax_error(other)
    end
  catch
    :invalid ->
      {:error, :invalid}
    {:invalid, token} ->
      {:error, {:invalid, token}}
  end

  @spec parse!(iodata) :: t
  def parse!(iodata) do
    case parse(iodata) do
      {:ok, value} -> value
      {:error, :invalid} -> raise SyntaxError
      {:error, {:invalid, token}} ->
        raise SyntaxError, token: token
    end
  end

  # Common base cases
  defp value("i0e" <> rest), do: {0, rest}
  defp value("0:" <> rest), do: {"", rest}
  defp value("le" <> rest), do: {[], rest}
  defp value("de" <> rest), do: {%{}, rest}

  # *{data}e cases
  defp value("i" <> rest), do: integer_start(rest)
  defp value("l" <> rest), do: list_values(rest, [])
  defp value("d" <> rest), do: map_pairs(rest, [])

  # String case
  defp value(<<c>> <> _ = str) when c in '123456789', do: string_length(str, [])

  # No other valid cases when starting to parse a bencoded string
  defp value(other), do: syntax_error(other)

  ## Integers

  # Error cases
  defp integer_start("e" <> _),   do: syntax_error("ie")
  defp integer_start("-e" <> _),  do: syntax_error("i-e")
  defp integer_start("-0e" <> _), do: syntax_error("i-0e")
  defp integer_start("0" <> _),   do: syntax_error("i0#e")
  defp integer_start("-0" <> _),  do: syntax_error("i-0#e")

  # Integer parsing
  defp integer_start(<<char, rest :: binary>>) when char in '-123456789' do
    integer_continue(rest, [char])
  end
  defp integer_start(other), do: syntax_error(other)

  defp integer_continue("e" <> rest, acc) do
    {acc |> Enum.reverse() |>  IO.iodata_to_binary() |> String.to_integer(), rest}
  end
  defp integer_continue(<<digit>> <> rest, acc) when digit in '0123456789' do
    integer_continue(rest, [digit | acc])
  end
  defp integer_continue(other, _acc), do: syntax_error(other)

  ## Strings

  defp string_length(<<digit>> <> rest, acc) when digit in '0123456789' do
    string_length(rest, [digit | acc])
  end
  defp string_length(":" <> rest, acc) do
    string_contents(acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.to_integer(), rest)
  end
  defp string_length(other, _acc), do: syntax_error(other)

  defp string_contents(len, str) when len > byte_size(str) do
    syntax_error("#{len} > #{byte_size(str)}")
  end
  defp string_contents(len, str) do
    <<contents :: binary-size(len), rest :: binary>> = str
    {contents, rest}
  end

  ## Lists

  defp list_values(str, acc) do
    {value, rest} = value(str)

    acc = [value | acc]
    case rest do
      "e" <> rest -> {acc |> Enum.reverse(), rest}
      "" -> syntax_error()
      rest -> list_values(rest, acc)
    end
  end

  ## Maps

  defp map_pairs(str, acc) do
    {name, rest} = value(str)
    unless is_binary(name), do: syntax_error("non-string key")

    {value, rest} = value(rest)

    acc = [{name, value} | acc]
    case rest do
      "e" <> rest -> {acc |> Map.new, rest}
      "" -> syntax_error()
      rest -> map_pairs(rest, acc)
    end
  end

  ## Errors
  defp syntax_error(token) do
    throw({:invalid, token})
  end
  defp syntax_error() do
    throw(:invalid)
  end
end
