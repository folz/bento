defmodule Bento.Tracker.HTTP.RouteTest do
  use ExUnit.Case, async: true

  alias Bento.Tracker.HTTP.Route

  test "literal routes match exactly" do
    assert Route.match(["/announce"], "/announce") == {:ok, []}
    assert Route.match(["/announce", "/announce.php"], "/announce.php") == {:ok, []}
    assert Route.match(["/announce"], "/announce/") == :error
    assert Route.match(["/announce"], "/scrape") == :error
  end

  test "named segments bind exactly one non-empty segment" do
    assert Route.match(["/:passkey/announce"], "/abc123/announce") ==
             {:ok, [{"passkey", "abc123"}]}

    assert Route.match(["/:a/:b"], "/x/y") == {:ok, [{"a", "x"}, {"b", "y"}]}
    assert Route.match(["/:passkey/announce"], "//announce") == :error
    assert Route.match(["/:passkey/announce"], "/a/b/announce") == :error
  end

  test "a trailing catch-all binds the rest of the path with its leading slash" do
    assert Route.match(["/announce/*rest"], "/announce/") == {:ok, [{"rest", "/"}]}
    assert Route.match(["/announce/*rest"], "/announce/a/b") == {:ok, [{"rest", "/a/b"}]}
    assert Route.match(["/announce/*rest"], "/scrape/a") == :error
  end

  test "the first matching route wins" do
    assert Route.match(["/:key/announce", "/announce"], "/announce") == {:ok, []}
    assert Route.match(["/:key/announce", "/announce"], "/k/announce") == {:ok, [{"key", "k"}]}
  end
end
