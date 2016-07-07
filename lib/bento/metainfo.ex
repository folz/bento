defmodule Bento.MetainfoError do
  defexception [:message]
end

defmodule Bento.Metainfo do
  @moduledoc """
  A batteries-included metainfo decoder. You probably want to use
  `Bento.torrent/1`
  """

  defmodule Torrent do
    defstruct [:info, :announce, :"announce-list", :"creation date", :comment,
               :"created by", :encoding]
    @type info :: SingleFile.t | MultiFile.t
    @type t :: %__MODULE__{info: info, announce: String.t, "announce-list": [[String.t]],
                           "creation date": integer, comment: String.t, "created by": String.t,
                           encoding: String.t}
  end

  defmodule SingleFile do
    defstruct [:"piece length", :pieces, :private, :name, :length, :md5sum]
    @type t :: %__MODULE__{"piece length": integer, pieces: String.t, private: integer,
                           name: String.t, length: integer, md5sum: String.t}
  end

  defmodule MultiFile do
    defstruct [:"piece length", :pieces, :private, :name, :files]
    @type t :: %__MODULE__{"piece length": integer, pieces: String.t, private: integer,
                           name: String.t, files: [...]}
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
    {:error, "Invalid torrent file (does not contain info.files or info.length)"}
  end

  def info!(torrent) do
    case info(torrent) do
      {:ok, value} -> value
      {:error, msg} -> raise Bento.MetainfoError, message: msg
    end
  end

  defp transform(info_dict) do
    info_dict |> Map.to_list() |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
  end
end
