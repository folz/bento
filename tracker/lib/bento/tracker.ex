defmodule Bento.Tracker do
  @moduledoc """
  A BitTorrent tracker for the BEAM, ported from
  [chihaya](https://github.com/chihaya/chihaya).

  `Bento.Tracker` is a standalone OTP application living alongside the
  Bento bencoding library, which it uses for all bencoding. It aims for
  feature parity with chihaya:

    * HTTP and UDP tracker frontends (BEP 3, BEP 15, BEP 41)
    * IPv4 and IPv6 support
    * Pre/post middleware hooks
    * Pluggable peer storage (in-memory and Redis)
    * Prometheus-compatible metrics
  """
end
