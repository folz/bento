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

  # Common constant cases
  defp value("i0e"), do: {0, ""}
  defp value("0:"), do: {"", ""}
  defp value("le"), do: {[], ""}
  defp value("de"), do: {%{}, ""}

  # *{data}e cases
  defp value("i" <> rest), do: integer_start(rest)
  #defp value("l" <> rest), do: list_values(rest, [])
  #defp value("d" <> rest), do: object_pairs(rest, [])

  # String case
  #defp value(<<char, _ :: binary>> = str) when char in '0123456789' do
  #  string_start(str)
  #end

  # No other valid cases when starting to parse a bencoded string
  defp value(other), do: syntax_error(other)

  ## Integers

  # Error cases
  defp integer_start("e" <> _) do
    syntax_error("ie")
  end
  defp integer_start("-e" <> _) do
    syntax_error("i-e")
  end
  defp integer_start("-0e" <> _) do
    syntax_error("i-0e")
  end
  defp integer_start("0" <> _) do
    syntax_error("i0#e")
  end
  defp integer_start("-0" <> _) do
    syntax_error("i-0#e")
  end

  # Integer parsing
  defp integer_start(<<char, rest :: binary>>) when char in '-123456789' do
    integer_continue(rest, [char])
  end
  defp integer_start(other) do
    syntax_error(other)
  end
  defp integer_continue("e" <> rest, acc) do
    {acc |> Enum.reverse() |>  IO.iodata_to_binary() |> String.to_integer(), rest}
  end
  defp integer_continue(<<digit>> <> rest, acc) when digit in '0123456789' do
    integer_continue(rest, [digit | acc])
  end
  defp integer_continue(other, _acc) do
    syntax_error(other)
  end

  ## Errors
  defp syntax_error(token) do
    throw({:invalid, token})
  end
  defp syntax_error() do
    throw(:invalid)
  end
end
