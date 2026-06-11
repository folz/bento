defmodule Bento.MetainfoError do
  defexception [:message]
end

defmodule Bento.Metainfo do
  @moduledoc """
  A batteries-included metainfo decoder.

  You probably want to use `Bento.torrent/1` instead of this module directly.

  Unknown keys are ignored, except nonstandard "name.utf-8" and "path.utf-8", which are decoded.
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
  alias Bento.OrderedDict

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

  @doc """
  Compute the v1 (SHA-1) info-hash of a torrent metainfo file.

  Takes the raw bencoded bytes of the file - not a decoded
  `Bento.Metainfo.Torrent` struct, which may have dropped unknown keys
  and would hash incorrectly. The hash is computed over the exact bytes
  of the info dictionary as they appear in the input (decoded with
  `dicts: :ordered` and re-encoded byte-for-byte), so it matches the
  hash other BitTorrent clients compute even for non-canonical files.

  Returns the hash as a raw 20-byte binary:

      iex> File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
      ...> |> Bento.Metainfo.info_hash!()
      ...> |> Base.encode16(case: :lower)
      "33395da120c9a4758e896ded4dec5f2495c9973f"

  Returns an error for torrents with no v1 data (BEP-52 v2-only
  torrents have no `pieces` key); see `info_hash_v2/1` for those.
  """
  @spec info_hash(iodata()) :: {:ok, <<_::160>>} | failure
        when failure: {:error, Bento.SyntaxError.t() | String.t()}
  def info_hash(metainfo) do
    with {:ok, info} <- raw_info(metainfo) do
      case OrderedDict.fetch(info, "pieces") do
        {:ok, _} -> {:ok, :crypto.hash(:sha, Bento.encode!(info))}
        :error -> {:error, "Not a v1 torrent: the info dictionary has no pieces key"}
      end
    end
  end

  @doc """
  Like `info_hash/1`, but raises on error.
  """
  @spec info_hash!(iodata()) :: <<_::160>> | no_return()
  def info_hash!(metainfo), do: unwrap!(info_hash(metainfo))

  @doc """
  Compute the v2 (SHA-256) info-hash of a BEP-52 torrent metainfo file.

  Takes the raw bencoded bytes of the file, like `info_hash/1`, and
  returns the hash as a raw 32-byte binary. Returns an error unless the
  info dictionary declares `meta version` 2 (a v2 or hybrid torrent):
  for other inputs a SHA-256 of the info dictionary identifies nothing.
  """
  @spec info_hash_v2(iodata()) :: {:ok, <<_::256>>} | failure
        when failure: {:error, Bento.SyntaxError.t() | String.t()}
  def info_hash_v2(metainfo) do
    with {:ok, info} <- raw_info(metainfo) do
      case OrderedDict.fetch(info, "meta version") do
        {:ok, 2} -> {:ok, :crypto.hash(:sha256, Bento.encode!(info))}
        _ -> {:error, "Not a v2 torrent: the info dictionary has no meta version 2 key"}
      end
    end
  end

  @doc """
  Like `info_hash_v2/1`, but raises on error.
  """
  @spec info_hash_v2!(iodata()) :: <<_::256>> | no_return()
  def info_hash_v2!(metainfo), do: unwrap!(info_hash_v2(metainfo))

  defp raw_info(metainfo) do
    with {:ok, %OrderedDict{} = meta} <- decode_dict(metainfo) do
      case {Enum.count(meta, fn {key, _} -> key == "info" end), OrderedDict.fetch(meta, "info")} do
        {1, {:ok, %OrderedDict{} = info}} -> {:ok, info}
        {1, {:ok, _other}} -> {:error, "Invalid metainfo file: info is not a dictionary"}
        {0, _} -> {:error, "Invalid metainfo file: missing info dictionary"}
        # Duplicate keys would make the hash ambiguous.
        {_, _} -> {:error, "Invalid metainfo file: duplicate info dictionary"}
      end
    end
  end

  defp decode_dict(metainfo) do
    case Bento.decode(metainfo, dicts: :ordered) do
      {:ok, %OrderedDict{} = meta} -> {:ok, meta}
      {:ok, _other} -> {:error, "Invalid metainfo file: not a dictionary"}
      {:error, error} -> {:error, error}
    end
  end

  defp unwrap!(result) do
    case result do
      {:ok, value} -> value
      {:error, %Bento.SyntaxError{} = error} -> raise error
      {:error, msg} -> raise Bento.MetainfoError, message: msg
    end
  end
end
