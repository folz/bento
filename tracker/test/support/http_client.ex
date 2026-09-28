defmodule Bento.Tracker.HTTPClient do
  @moduledoc """
  A raw-socket HTTP/1.1 client for exercising `Bento.Tracker.HTTP.Server`
  in tests: one request per connection, which the server then closes.
  """

  @doc """
  Sends `method target` to 127.0.0.1:`port` and returns
  `{status_line, head, body}` once the server closes the connection.

  Options: `:headers` (extra header lines), `:version` (`"1.1"`), and
  `:close` (send `Connection: close`, default `true`).
  """
  def request(port, method, target, opts \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5000)
    version = Keyword.get(opts, :version, "1.1")
    close = if Keyword.get(opts, :close, true), do: ["Connection: close"], else: []
    head = Enum.join(["Host: t" | close ++ Keyword.get(opts, :headers, [])], "\r\n")
    :ok = :gen_tcp.send(socket, "#{method} #{target} HTTP/#{version}\r\n#{head}\r\n\r\n")
    response = recv_all(socket, <<>>)
    :gen_tcp.close(socket)

    [head, body] = :binary.split(response, "\r\n\r\n")
    [status | _headers] = :binary.split(head, "\r\n")
    {status, head, body}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, _reason} -> acc
    end
  end
end
