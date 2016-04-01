defmodule PerfBench do
  use Benchfella

  bench "encode strings", string: gen_string do
    Bento.Encoder.encode(string)
  end

  bench "encode lists", list: gen_list do
    Bento.Encoder.encode(list)
  end

  bench "encode maps", map: gen_map do
    Bento.Encoder.encode(map)
  end

  bench "encode single", torrent: gen_single do
    Bento.Encoder.encode(torrent)
  end

  bench "encode multi", torrent: gen_multi do
    Bento.Encoder.encode(torrent)
  end

  bench "parse single", single: gen_single_str do
    Bento.Parser.parse!(single)
  end

  bench "parse multi", multi: gen_multi_str do
    Bento.Parser.parse!(multi)
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

  defp gen_single_str do
    File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
  end

  defp gen_multi_str do
    File.read!("test/_data/huck_finn_librivox_archive.torrent")
  end
end
