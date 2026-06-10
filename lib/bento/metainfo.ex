defmodule Bento.MetainfoError do
  defexception [:message]
end

defmodule Bento.Metainfo do
  @moduledoc """
  A batteries-included metainfo decoder.

  You probably want to use `Bento.torrent/1` instead of this module directly.

  Keys are not restricted by the spec, so metainfo files may contain
  nonstandard keys. Unrecognized keys are ignored when decoding into the
  structs below, with the exception of the `"name.utf-8"` and
  `"path.utf-8"` keys written by some clients, which are decoded into the
  fields of the same name.
  """

  defmodule SingleFile do
    @moduledoc """
    A struct representing a single-file torrent metainfo file.

    The nonstandard `"name.utf-8"` key written by some clients (e.g.
    Vuze/Azureus) is decoded when present, holding the UTF-8 encoded
    `name` of torrents whose standard fields use a legacy charset.
    """

    defstruct length: nil,
              md5sum: nil,
              "piece length": nil,
              pieces: nil,
              private: 0,
              name: nil,
              "name.utf-8": nil

    @type t :: %__MODULE__{
            "piece length": integer(),
            pieces: String.t(),
            private: integer(),
            name: String.t(),
            "name.utf-8": String.t(),
            length: integer(),
            md5sum: String.t()
          }
  end

  defmodule MultiFile do
    @moduledoc """
    A struct representing a multi-file torrent metainfo file.

    The nonstandard `"name.utf-8"` and `"path.utf-8"` keys written by
    some clients (e.g. Vuze/Azureus) are decoded when present, holding
    the UTF-8 encoded `name` and file `path`s of torrents whose
    standard fields use a legacy charset.
    """

    defstruct files: [%{path: [], length: nil, "path.utf-8": nil}],
              "piece length": nil,
              pieces: nil,
              private: 0,
              name: nil,
              "name.utf-8": nil

    @type t :: %__MODULE__{
            files: [
              %{path: [String.t()], length: integer(), "path.utf-8": [String.t()]}
            ],
            "piece length": integer(),
            pieces: String.t(),
            private: integer(),
            name: String.t(),
            "name.utf-8": String.t()
          }
  end

  defmodule Torrent do
    @moduledoc """
    A struct representing a torrent metainfo file.
    """

    alias Bento.Metainfo.{SingleFile, MultiFile}

    defstruct info: nil,
              announce: nil,
              "announce-list": [[]],
              "creation date": ~U[1970-01-01 00:00:00Z],
              comment: nil,
              "created by": nil,
              encoding: nil

    @type t :: %__MODULE__{
            info: SingleFile.t() | MultiFile.t(),
            announce: String.t(),
            "announce-list": [[String.t()]],
            "creation date": integer(),
            comment: String.t(),
            "created by": String.t(),
            encoding: String.t()
          }
  end

  alias Bento.Decoder

  def info(torrent = %{info: %{"files" => _}}) do
    with {:module, _} <- Code.ensure_loaded(MultiFile) do
      {:ok, Decoder.transform(torrent.info, as: %MultiFile{})}
    else
      {:error, _} -> {:error, "Multi-file torrents are not supported"}
    end
  end

  def info(torrent = %{info: %{"length" => _}}) do
    with {:module, _} <- Code.ensure_loaded(SingleFile) do
      {:ok, Decoder.transform(torrent.info, as: %SingleFile{})}
    else
      {:error, _} -> {:error, "Single-file torrents are not supported"}
    end
  end

  def info(_) do
    {:error, "Invalid metainfo file: missing info.files or info.length"}
  end

  def info!(torrent) do
    case info(torrent) do
      {:ok, value} -> value
      {:error, msg} -> raise Bento.MetainfoError, message: msg
    end
  end
end
