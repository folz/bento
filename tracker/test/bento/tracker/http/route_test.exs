defmodule Bento.Tracker.HTTP.RouteTest do
  use ExUnit.Case, async: true

  alias Bento.Tracker.HTTP.Route

  test "literal routes match exactly" do
    assert Route.match(["/announce"], "/announce") == []
    assert Route.match(["/announce", "/announce.php"], "/announce.php") == []
    assert Route.match(["/announce"], "/announce/") == nil
    assert Route.match(["/announce"], "/scrape") == nil
  end

  test "named segments bind exactly one non-empty segment" do
    assert Route.match(["/:passkey/announce"], "/abc123/announce") == [{"passkey", "abc123"}]
    assert Route.match(["/:a/:b"], "/x/y") == [{"a", "x"}, {"b", "y"}]
    assert Route.match(["/:passkey/announce"], "//announce") == nil
    assert Route.match(["/:passkey/announce"], "/a/b/announce") == nil
  end

  test "a trailing catch-all binds the rest of the path with its leading slash" do
    assert Route.match(["/announce/*rest"], "/announce/") == [{"rest", "/"}]
    assert Route.match(["/announce/*rest"], "/announce/a/b") == [{"rest", "/a/b"}]
    assert Route.match(["/announce/*rest"], "/scrape/a") == nil
  end

  test "the first matching route wins" do
    assert Route.match(["/:key/announce", "/announce"], "/announce") == []
    assert Route.match(["/:key/announce", "/announce"], "/k/announce") == [{"key", "k"}]
  end
end
