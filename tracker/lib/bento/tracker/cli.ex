defmodule Bento.Tracker.CLI do
  @moduledoc """
  Command-line entry point for the tracker, the equivalent of chihaya's
  `cmd/chihaya`.

  Usage:

      bento_tracker --config path/to/config.exs   # run the tracker
      bento_tracker e2e [--httpaddr URL] [--udpaddr URL] [--delay MS]

  The run command starts the tracker from the given configuration and
  blocks until it receives SIGINT/SIGTERM.
  """

  alias Bento.Tracker.E2E
  alias Bento.Tracker.Runner

  @default_config "/etc/bento_tracker.exs"
  @default_http_addr "http://127.0.0.1:6969/announce"
  @default_udp_addr "udp://127.0.0.1:6969"
  @default_delay 1000

  @doc "Escript entry point."
  @spec main([String.t()]) :: no_return()
  def main(args) do
    :inets.start()

    case args do
      ["e2e" | rest] -> run_e2e(rest)
      _run -> run_tracker(args)
    end
  end

  defp run_tracker(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [config: :string])
    config_path = Keyword.get(opts, :config, @default_config)

    case Runner.start_link(config_path) do
      {:ok, pid} ->
        IO.puts(:stderr, "bento_tracker running (config: #{config_path}); press Ctrl-C to stop")
        wait_for_signal(pid)

      {:error, reason} ->
        IO.puts(:stderr, "failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_e2e(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [httpaddr: :string, udpaddr: :string, delay: :string]
      )

    result =
      E2E.run(
        http_addr: Keyword.get(opts, :httpaddr, @default_http_addr),
        udp_addr: Keyword.get(opts, :udpaddr, @default_udp_addr),
        delay: parse_delay(Keyword.get(opts, :delay))
      )

    case result do
      :ok ->
        IO.puts("e2e: success")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "e2e: failure: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Accepts a Go-style duration ("1s", "500ms") like chihaya's --delay,
  # or a bare integer count of milliseconds.
  defp parse_delay(nil), do: @default_delay

  defp parse_delay(value) do
    case Integer.parse(value) do
      {ms, ""} -> ms
      _not_plain_integer -> Bento.Tracker.Config.parse_duration_ms(value) || @default_delay
    end
  end

  # Blocks forever; the BEAM's default SIGINT/SIGTERM handling halts the VM.
  defp wait_for_signal(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        IO.puts(:stderr, "tracker stopped: #{inspect(reason)}")
        System.halt(if reason == :normal, do: 0, else: 1)
    end
  end
end
