defmodule Transitmaps.Gtfs.GeoJsonCacheTermsTest do
  # Turns the cache on for the whole app while it runs, so not async.
  use ExUnit.Case, async: false

  alias Transitmaps.Gtfs.GeoJsonCache

  setup do
    Application.put_env(:transitmaps, :geojson_cache, true)
    on_exit(fn -> Application.put_env(:transitmaps, :geojson_cache, false) end)
  end

  test "keeps a term until an import invalidates its feed" do
    key = {:test_term, System.unique_integer([:positive]), ["rail"]}
    {_kind, feed_id, _categories} = key

    assert GeoJsonCache.fetch_term(key, fn -> :first end) == :first
    assert GeoJsonCache.fetch_term(key, fn -> :second end) == :first

    GeoJsonCache.invalidate(fn
      {_kind, ^feed_id, _categories} -> true
      _key -> false
    end)

    assert GeoJsonCache.fetch_term(key, fn -> :second end) == :second
  end
end
