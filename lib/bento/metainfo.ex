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

    defstruct [:"piece length", :pieces, :private, :name, :length, :md5sum]

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

    defstruct [:"piece length", :pieces, :private, :name, :files]

    @type t :: %__MODULE__{
            "piece length": integer(),
            pieces: String.t(),
            private: integer(),
            name: String.t(),
            files: [...]
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

    @type info :: SingleFile.t() | MultiFile.t()
    @type t :: %__MODULE__{
            info: info(),
            announce: String.t(),
            "announce-list": [[String.t()]],
            "creation date": integer(),
            comment: String.t(),
            "created by": String.t(),
            encoding: String.t()
          }
  end

  def info(torrent = %{info: %{"files" => _}}) do
    Code.ensure_loaded(MultiFile)
    {:ok, struct(MultiFile, transform(torrent.info))}
  end

  def info(torrent = %{info: %{"length" => _}}) do
    Code.ensure_loaded(SingleFile)
    {:ok, struct(SingleFile, transform(torrent.info))}
  end

  def info(_) do
    {:error, "Invalid metainfo file: missing info.files or info.length."}
  end

  def info!(torrent) do
    case info(torrent) do
      {:ok, value} -> value
      {:error, msg} -> raise Bento.MetainfoError, message: msg
    end
  end

  @fields [:"piece length", :pieces, :private, :name, :files, :length, :md5sum]

  defp transform(info_dict) do
    Enum.map(@fields, fn field ->
      {field, Map.get(info_dict, Atom.to_string(field))}
    end)
  end
end
