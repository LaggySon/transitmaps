defmodule Transitmaps.Gtfs.GeoJsonStoreTest do
  # Turns the application-wide cache on, so it cannot run alongside the
  # async tests that rely on it being off.
  use Transitmaps.DataCase, async: false

  alias Transitmaps.Gtfs.{GeoJsonCache, GeoJsonStore}

  setup do
    Application.put_env(:transitmaps, :geojson_cache, true)
    on_exit(fn -> Application.put_env(:transitmaps, :geojson_cache, false) end)
  end

  defp entry(term) do
    body = Jason.encode!(term)
    {body, :zlib.gzip(body), ~s("etag-#{System.unique_integer([:positive])}")}
  end

  test "keeps a response and gives it back, with its age" do
    key = {:routes, 12, ["rail"]}
    stored = entry(%{lines: 3})

    assert GeoJsonStore.get(key) == nil
    assert :ok = GeoJsonStore.put(key, stored)

    assert {^stored, age_ms} = GeoJsonStore.get(key)
    assert age_ms < 60_000

    # Kept again, it replaces the old one.
    newer = entry(%{lines: 4})
    GeoJsonStore.put(key, newer)
    assert {^newer, _age_ms} = GeoJsonStore.get(key)
  end

  test "only slow responses are worth keeping" do
    refute GeoJsonStore.worth_keeping?(20)
    assert GeoJsonStore.worth_keeping?(2_000)
  end

  # After a restart memory is empty, but the database still has it.
  test "a kept response is served without building it again" do
    key = {:routes, [make_ref()]}
    stored = entry(%{kept: true})
    GeoJsonStore.put(key, stored)

    refute GeoJsonCache.cached?(key)
    assert GeoJsonCache.fetch(key, fn -> flunk("built again") end) == stored
    assert GeoJsonCache.cached?(key)
  end

  test "prunes responses no one has looked at for weeks" do
    old = {:routes, :old}
    recent = {:routes, :recent}
    GeoJsonStore.put(old, entry(%{}))
    GeoJsonStore.put(recent, entry(%{}))

    weeks_ago = DateTime.add(DateTime.utc_now(:second), -30, :day)
    Repo.update_all(Transitmaps.Gtfs.GeoJsonResponse, set: [built_at: weeks_ago])
    GeoJsonStore.put(recent, entry(%{}))

    assert GeoJsonStore.prune() == 1
    assert GeoJsonStore.get(old) == nil
    assert GeoJsonStore.get(recent)
  end
end
