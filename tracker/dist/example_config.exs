# Example bento_tracker configuration.
#
# This mirrors chihaya's dist/example_config.yaml as an Elixir map so the
# tracker needs no YAML dependency. Duration values accept chihaya-style
# strings ("30m", "15s") or integers. Pass this file's path to the CLI:
#
#     bento_tracker --config dist/example_config.exs
%{
  bento_tracker: %{
    # The interval communicated with BitTorrent clients informing them how
    # frequently they should announce between client events.
    announce_interval: "30m",
    # The minimal duration between announces communicated with clients.
    min_announce_interval: "15m",
    # The address of the Prometheus metrics endpoint (/metrics).
    metrics_addr: "0.0.0.0:6880",

    # The tracker's HTTP interface. Remove this section to disable it.
    http: %{
      # The plain-HTTP listen address. Remove to disable the non-TLS listener.
      addr: "0.0.0.0:6969",
      # The TLS listen address; requires tls_cert_path and tls_key_path.
      https_addr: "",
      tls_cert_path: "",
      tls_key_path: "",
      read_timeout: "5s",
      write_timeout: "5s",
      # When true, persistent connections are allowed.
      enable_keepalive: false,
      idle_timeout: "30s",
      # Whether to time requests (increases load slightly).
      enable_request_timing: false,
      # Routes to listen on for announce and scrape requests.
      announce_routes: ["/announce"],
      scrape_routes: ["/scrape"],
      # When enabled, clients may advertise their own IP address.
      allow_ip_spoofing: false,
      # The HTTP header carrying the client IP, when behind a reverse proxy.
      real_ip_header: "x-real-ip",
      max_numwant: 100,
      default_numwant: 50,
      max_scrape_infohashes: 50
    },

    # The tracker's UDP interface. Remove this section to disable it.
    udp: %{
      addr: "0.0.0.0:6969",
      # The leeway for a connection ID's timestamp.
      max_clock_skew: "10s",
      # The key used to HMAC connection IDs. A random key is generated when
      # empty, but a stable key is recommended across restarts.
      private_key: "paste a random string here that will be used to hmac connection IDs",
      enable_request_timing: false,
      allow_ip_spoofing: false,
      max_numwant: 100,
      default_numwant: 50,
      max_scrape_infohashes: 50
    },

    # Peer storage.
    storage: %{
      name: "memory",
      config: %{
        # How frequently stale peers are removed.
        gc_interval: "3m",
        # How long until a peer is considered stale. Keep slightly larger
        # than announce_interval to avoid churn.
        peer_lifetime: "31m",
        # The number of shards per address family.
        shard_count: 1024,
        # How often peer/infohash counts are posted to Prometheus.
        prometheus_reporting_interval: "1s"
      }
    },

    # Middleware run before the response is returned to the client.
    prehooks: [],
    # Middleware run after the response is returned to the client.
    posthooks: []
  }
}
