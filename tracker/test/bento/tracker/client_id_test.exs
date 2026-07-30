defmodule Bento.Tracker.ClientIDTest do
  # Ported from chihaya's bittorrent/client_id_test.go
  use ExUnit.Case, async: true

  alias Bento.Tracker.ClientID

  @client_table [
    {"-AZ3034-6wfG2wk6wWLc", "AZ3034"},
    {"-AZ3042-6ozMq5q6Q3NX", "AZ3042"},
    {"-BS5820-oy4La2MWGEFj", "BS5820"},
    {"-AR6360-6oZyyMWoOOBe", "AR6360"},
    {"-AG2083-s1hiF8vGAAg0", "AG2083"},
    {"-AG3003-lEl2Mm4NEO4n", "AG3003"},
    {"-MR1100-00HS~T7*65rm", "MR1100"},
    {"-LK0140-ATIV~nbEQAMr", "LK0140"},
    {"-KT2210-347143496631", "KT2210"},
    {"-TR0960-6ep6svaa61r4", "TR0960"},
    {"-XX1150-dv220cotgj4d", "XX1150"},
    {"-AZ2504-192gwethivju", "AZ2504"},
    {"-KT4310-3L4UvarKuqIu", "KT4310"},
    {"-AZ2060-0xJQ02d4309O", "AZ2060"},
    {"-BD0300-2nkdf08Jd890", "BD0300"},
    {"-A~0010-a9mn9DFkj39J", "A~0010"},
    {"-UT2300-MNu93JKnm930", "UT2300"},
    {"-UT2300-KT4310KT4301", "UT2300"},
    {"T03A0----f089kjsdf6e", "T03A0-"},
    {"S58B-----nKl34GoNb75", "S58B--"},
    {"M4-4-0--9aa757Efd5Bl", "M4-4-0"},
    # BitTyrant
    {"AZ2500BTeYUzyabAfo6U", "AZ2500"},
    # Old BitComet
    {"exbc0JdSklm834kj9Udf", "exbc0J"},
    # Alt BitComet
    {"FUTB0L84j542mVc84jkd", "FUTB0L"},
    # XBT
    {"XBT054d-8602Jn83NnF9", "XBT054"},
    # Opera
    {"OP1011affbecbfabeefb", "OP1011"},
    # MLDonkey
    {"-ML2.7.2-kgjjfkd9762", "ML2.7."},
    # Bits on Wheels
    {"-BOWA0C-SDLFJWEIORNM", "BOWA0C"},
    # Queen Bee
    {"Q1-0-0--dsn34DFn9083", "Q1-0-0"},
    # Queen Bee Alt
    {"Q1-10-0-Yoiumn39BDfO", "Q1-10-"},
    # TorreTopia
    {"346------SDFknl33408", "346---"},
    # Qvod
    {"QVOD0054ABFFEDCCDEDB", "QVOD00"}
  ]

  test "new/1 extracts the client ID from a peer ID" do
    for {peer_id, client_id} <- @client_table do
      parsed = peer_id |> Bento.Tracker.PeerID.from_binary!() |> ClientID.new()
      assert parsed == client_id, "incorrectly parsed peer ID #{peer_id} as #{parsed}"
    end
  end
end
