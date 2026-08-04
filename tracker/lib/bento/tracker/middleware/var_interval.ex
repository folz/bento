defmodule Bento.Tracker.Middleware.VarInterval do
  @moduledoc """
  A hook that modifies announce intervals according to configured ranges,
  giving different values for each peer so they don't re-announce at the
  same time.

  The modification is deterministic per (infohash, peer ID) pair: the
  XORShift128Plus generator is seeded from the request via
  `Bento.Tracker.Random.derive_entropy_from_request/1`.

  ## Options

    * `:modify_response_probability` - the probability by which a
      response will be modified; must be in `(0, 1]`
    * `:max_increase_delta` - the number of seconds that will be added at
      most; must be positive
    * `:modify_min_interval` - whether `min_interval` should be increased
      as well
  """

  @behaviour Bento.Tracker.Middleware.Hook

  import Bitwise

  alias Bento.Tracker.Middleware
  alias Bento.Tracker.Random

  @impl true
  def new(options) do
    config = %{
      modify_response_probability:
        Middleware.get_option(options, :modify_response_probability) || 0.0,
      max_increase_delta: Middleware.get_option(options, :max_increase_delta) || 0,
      modify_min_interval: Middleware.get_option(options, :modify_min_interval) || false
    }

    with :ok <- check_config(config) do
      {:ok, config}
    end
  end

  defp check_config(config) do
    cond do
      not is_number(config.modify_response_probability) or
        config.modify_response_probability <= 0 or config.modify_response_probability > 1 ->
        {:error, :invalid_modify_response_probability}

      not is_integer(config.max_increase_delta) or config.max_increase_delta <= 0 ->
        {:error, :invalid_max_increase_delta}

      true ->
        :ok
    end
  end

  @impl true
  def handle_announce(config, ctx, request, response) do
    {s0, s1} = Random.derive_entropy_from_request(request)

    # Generate a probability p < 1.0.
    {v, s0, s1} = Random.intn(s0, s1, 1 <<< 24)
    p = v / (1 <<< 24)

    if config.modify_response_probability == 1 or p < config.modify_response_probability do
      # Generate the increase delta.
      {v, _s0, _s1} = Random.intn(s0, s1, config.max_increase_delta)
      delta = v + 1

      response = %{response | interval: response.interval + delta}

      response =
        if config.modify_min_interval do
          %{response | min_interval: response.min_interval + delta}
        else
          response
        end

      {:ok, ctx, response}
    else
      {:ok, ctx, response}
    end
  end

  @impl true
  def handle_scrape(_config, ctx, _request, response) do
    # Scrapes are not altered.
    {:ok, ctx, response}
  end
end
