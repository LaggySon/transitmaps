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

  test "builds at most two terms at a time" do
    counter = :counters.new(2, [])

    builder = fn ->
      :counters.add(counter, 1, 1)
      now = :counters.get(counter, 1)
      if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
      Process.sleep(50)
      :counters.sub(counter, 1, 1)
      :built
    end

    1..6
    |> Enum.map(fn n ->
      Task.async(fn ->
        GeoJsonCache.fetch_term(
          {:test_slots, System.unique_integer([:positive]) + n, []},
          builder
        )
      end)
    end)
    |> Task.await_many()
    |> Enum.each(&assert(&1 == :built))

    assert :counters.get(counter, 2) <= 2
  end
end
