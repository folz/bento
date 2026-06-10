defmodule Bento.Fragment do
  @moduledoc """
  Injects already-encoded Bencoding into a to-be-encoded structure
  without a decode/encode round-trip.

  Useful when part of the output is cached or produced elsewhere - for
  example the encoded `info` dictionary of a torrent (the part that gets
  hashed and served as-is), or pre-encoded blobs inside tracker
  responses.

      iex> info = Bento.encode!(%{"name" => "demo", "length" => 42})
      iex> Bento.encode!(%{"announce" => "http://example/", "info" => Bento.Fragment.new(info)})
      "d8:announce15:http://example/4:infod6:lengthi42e4:name4:demoee"

  The wrapped iodata is emitted verbatim; it is the caller's
  responsibility that it contains exactly one valid Bencoded value.
  """

  @type t :: %__MODULE__{iodata: iodata()}

  defstruct [:iodata]

  @doc """
  Wraps already-encoded Bencoding so the encoder emits it as-is.
  """
  @spec new(iodata()) :: t()
  def new(iodata) when is_binary(iodata) or is_list(iodata) do
    %__MODULE__{iodata: iodata}
  end
end
