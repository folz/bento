defmodule Bento.MetainfoError do
  defexception [:message]
end

defmodule Bento.Metainfo do
  @moduledoc """
  A batteries-included metainfo decoder.

  You probably want to use `Bento.torrent/1` instead of this module directly.
  """

  defmodule SingleFile do
    @moduledoc """
    A struct representing a single-file torrent metainfo file.
    """

    defstruct length: nil,
              md5sum: nil,
              "piece length": nil,
              pieces: nil,
              private: 0,
              name: nil

    @type t :: %__MODULE__{
            "piece length": integer(),
            pieces: String.t(),
            private: integer(),
            name: String.t(),
            length: integer(),
            md5sum: String.t()
          }
  end

  defmodule MultiFile do
    @moduledoc """
    A struct representing a multi-file torrent metainfo file.
    """

    defstruct files: [%{path: [], length: nil}],
              "piece length": nil,
              pieces: nil,
              private: 0,
              name: nil

    @type t :: %__MODULE__{
            files: [
              %{path: [String.t()], length: integer()}
            ],
            "piece length": integer(),
            pieces: String.t(),
            private: integer(),
            name: String.t()
          }
  end

  defmodule Torrent do
    @moduledoc """
    A struct representing a torrent metainfo file.
    """

    alias Bento.Metainfo.{SingleFile, MultiFile}

    defstruct [
      :info,
      :announce,
      :"announce-list",
      :"creation date",
      :comment,
      :"created by",
      :encoding
    ]

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
