# Agent instructions for Bento

Bento is a pure-Elixir library (no NIFs, no runtime deps). Everything an
agent needs is the BEAM toolchain plus four dev/test Hex packages from
`mix.lock` (`stream_data` for tests; `credo`, `dialyxir`, `ex_doc` and
their transitive deps for lint/typecheck/docs).

## Toolchain setup (sandboxed/cloud environments)

The project requires Elixir `~> 1.17` (see `mix.exs`); CI exercises
Elixir 1.17–1.20 on OTP 27–29 (see
`.github/workflows/build-test.yml`). In an environment with no BEAM
toolchain, this recipe works and takes a couple of minutes:

1. **Erlang via apt** (Ubuntu's Elixir is too old, but its Erlang is fine):

   ```shell
   sudo apt-get install -y elixir erlang-dev erlang-parsetools erlang-dialyzer
   ```

   `erlang-dev`/`erlang-parsetools` are required to compile `ex_doc`'s
   deps (leex headers); `erlang-dialyzer` for `mix dialyzer`. This also
   installs an Elixir that is too old - ignore it.

2. **Elixir from precompiled GitHub release**, matched to the installed
   OTP major (check with `erl -noshell -eval
   'io:format(erlang:system_info(otp_release)), halt().'`):

   ```shell
   curl -fsSL -o /tmp/elixir.zip \
     https://github.com/elixir-lang/elixir/releases/download/v1.17.3/elixir-otp-25.zip
   sudo mkdir -p /opt/elixir && sudo unzip -q -o /tmp/elixir.zip -d /opt/elixir
   ```

3. **Environment** (every shell; the harness does not persist exports):

   ```shell
   export PATH=/opt/elixir/bin:$PATH LC_ALL=C.UTF-8 ELIXIR_ERL_OPTIONS="+fnu"
   ```

   Without the locale settings the VM runs in latin1 filename mode and
   Elixir warns/misbehaves.

## Hex and deps behind a TLS-intercepting proxy

Cloud sandboxes often route egress through a proxy with a custom CA
(curl trusts it via `SSL_CERT_FILE`; Erlang/Hex bundle their own CA
store and don't). Symptoms and fixes, in escalating order:

1. `mix local.hex --force` fails (`bad_status_code` / `unknown_ca`):
   fetch the official archive with curl and install it from the local
   file, verifying its checksum against the manifest:

   ```shell
   curl -fsSL -o /tmp/hex-1.x.csv https://builds.hex.pm/installs/hex-1.x.csv
   # pick the newest line whose Elixir version <= yours, then:
   curl -fsSL -o /tmp/hex.ez https://builds.hex.pm/installs/<elixir>/hex-<version>.ez
   echo "<sha512-from-csv>  /tmp/hex.ez" | sha512sum -c -
   mix archive.install /tmp/hex.ez --force
   ```

2. `mix deps.get` fails with `unknown_ca`: point Hex at the system CA
   bundle:

   ```shell
   export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
   ```

3. `mix deps.get` still fails with upstream connection resets: mirror
   the few locked packages with curl (which the proxy tolerates) and
   serve them to Hex locally. Registry records and tarballs are
   signed, so this does not weaken verification:

   ```shell
   mkdir -p /tmp/hexmirror/packages /tmp/hexmirror/tarballs
   # for each `"name": {:hex, :name, "version", ...}` in mix.lock:
   curl -fsSL -o /tmp/hexmirror/packages/$name https://repo.hex.pm/packages/$name
   curl -fsSL -o /tmp/hexmirror/tarballs/$name-$ver.tar \
     https://repo.hex.pm/tarballs/$name-$ver.tar
   (cd /tmp/hexmirror && python3 -m http.server 8765 --bind 127.0.0.1 &)
   HEX_MIRROR=http://127.0.0.1:8765 mix deps.get
   ```

## Build, test, and checks

CI runs all of these; keep them green:

```shell
mix deps.get
mix test                      # full suite incl. doctests + property tests
mix format --check-formatted  # enforced by CI
mix dialyzer                  # enforced by CI (slow first run: builds PLT)
mix credo --strict            # advisory, not in CI; avoid adding new issues
```

Notes:

* `MIX_ENV=test` avoids compiling dev-only deps (`ex_doc`, `dialyxir`)
  when you only need the test suite.
* The benchmark suite under `bench/` is a standalone project; it is not
  needed for development and pulls extra deps - skip it unless asked.
* Test data lives in `test/_data/` (real torrent files) and
  `test/bencode_test_suite/` (accept/reject conformance vectors).
