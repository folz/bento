defmodule EncoderBench do
  use Benchfella

  bench "strings (Bento)", string: gen_string do
    Bento.Encoder.BitString.encode(string)
  end

  bench "strings (bencode)", string: gen_string do
    Bencode.encode!(string)
  end

  bench "strings (Bencodex)", string: gen_string do
    Bencodex.encode(string)
  end

  bench "strings (bencoder)", string: gen_string do
    Bencoder.encode(string)
  end

  bench "strings (bencoded)", string: gen_string do
    :bencoded.encode(string)
  end

  bench "lists (Bento)", list: gen_list do
    Bento.Encoder.List.encode(list)
  end

  bench "lists (bencode)", list: gen_list do
    Bencode.encode!(list)
  end

  bench "lists (Bencodex)", list: gen_list do
    Bencodex.encode(list)
  end

  bench "lists (bencoder)", list: gen_list do
    Bencoder.encode(list)
  end

  bench "lists (bencoded)", list: gen_list do
    :bencoded.encode(list)
  end

  bench "maps (Bento)", map: gen_map do
    Bento.Encoder.Map.encode(map)
  end

  bench "maps (bencode)", map: gen_map do
    Bencode.encode!(map)
  end

  bench "maps (Bencodex)", map: gen_map do
    Bencodex.encode(map)
  end

  bench "maps (bencoder)", map: gen_map do
    Bencoder.encode(map)
  end

  bench "maps (bencoded)", map: gen_map do
    :bencoded.encode(map)
  end

  bench "single (Bento)", torrent: gen_single do
    Bento.encode!(torrent)
  end

  bench "single (bencode)", torrent: gen_single do
    Bencode.encode!(torrent)
  end

  bench "single (Bencodex)", torrent: gen_single do
    Bencodex.encode(torrent)
  end

  bench "single (bencoder)", torrent: gen_single do
    Bencoder.encode(torrent)
  end

  bench "single (bencoded)", torrent: gen_single do
    :bencoded.encode(torrent)
  end

  bench "multi (Bento)", torrent: gen_multi do
    Bento.encode!(torrent)
  end

  bench "multi (bencode)", torrent: gen_multi do
    Bencode.encode!(torrent)
  end

  bench "multi (Bencodex)", torrent: gen_multi do
    Bencodex.encode(torrent)
  end

  bench "multi (bencoder)", torrent: gen_multi do
    Bencoder.encode(torrent)
  end

  bench "multi (bencoded)", torrent: gen_multi do
    :bencoded.encode(torrent)
  end

  defp gen_string do
    File.read!("test/_data/UTF-8-demo.txt")
  end

  defp gen_list do
    1..1000 |> Enum.to_list()
  end

  defp gen_map do
    Stream.map(?A..?Z, &<<&1>>) |> Stream.with_index |> Enum.into(%{})
  end

  defp gen_single do
    File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent") |> Bento.decode!()
  end

  defp gen_multi do
    File.read!("test/_data/huck_finn_librivox_archive.torrent") |> Bento.decode!()
  end
end
