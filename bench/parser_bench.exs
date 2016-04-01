defmodule ParserBench do
  use Benchfella

  bench "single (Bento)", single: gen_single do
    Bento.Parser.parse!(single)
  end

  bench "single (bencode)", single: gen_single do
    Bencode.decode!(single)
  end

  bench "single (Bencodex)", single: gen_single do
    Bencodex.decode(single)
  end

  bench "single (bencoder)", single: gen_single do
    Bencoder.decode(single)
  end

  bench "single (bencoded)", single: gen_single do
    :bencoded.decode(single)
  end

  bench "multi (Bento)", multi: gen_multi do
    Bento.Parser.parse!(multi)
  end

  bench "multi (bencode)", multi: gen_multi do
    Bencode.decode!(multi)
  end

  bench "multi (Bencodex)", multi: gen_multi do
    Bencodex.decode(multi)
  end

  bench "multi (bencoder)", multi: gen_multi do
    Bencoder.decode(multi)
  end

  bench "multi (bencoded)", multi: gen_multi do
    :bencoded.decode(multi)
  end

  defp gen_single do
    File.read!("test/_data/ubuntu-14.04.4-desktop-amd64.iso.torrent")
  end

  defp gen_multi do
    File.read!("test/_data/huck_finn_librivox_archive.torrent")
  end
end
