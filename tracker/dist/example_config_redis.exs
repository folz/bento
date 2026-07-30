# Example bento_tracker configuration using the Redis peer store.
#
# Identical to dist/example_config.exs except the storage section, which
# points at a Redis server. Mirrors chihaya's example_config_redis.yaml.
%{
  bento_tracker: %{
    announce_interval: "30m",
    min_announce_interval: "15m",
    metrics_addr: "0.0.0.0:6880",
    http: %{
      addr: "0.0.0.0:6969",
      read_timeout: "5s",
      write_timeout: "5s",
      idle_timeout: "30s",
      announce_routes: ["/announce"],
      scrape_routes: ["/scrape"],
      max_numwant: 100,
      default_numwant: 50,
      max_scrape_infohashes: 50
    },
    udp: %{
      addr: "0.0.0.0:6969",
      max_clock_skew: "10s",
      private_key: "paste a random string here that will be used to hmac connection IDs",
      max_numwant: 100,
      default_numwant: 50,
      max_scrape_infohashes: 50
    },
    storage: %{
      name: "redis",
      config: %{
        gc_interval: "3m",
        peer_lifetime: "31m",
        prometheus_reporting_interval: "1s",
        # The Redis connection URL: redis://[password@]host:port/db
        redis_broker: "redis://127.0.0.1:6379/0",
        redis_read_timeout: "15s",
        redis_write_timeout: "15s",
        redis_connect_timeout: "15s"
      }
    },
    prehooks: [],
    posthooks: []
  }
}
