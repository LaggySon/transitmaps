defmodule Transitmaps.Gtfs.GeoJsonCacheTest do
  # Turns the application-wide cache on, so it cannot run alongside the
  # async tests that rely on it being off.
  use ExUnit.Case, async: false

  alias Transitmaps.Gtfs.GeoJsonCache

  setup do
    Application.put_env(:transitmaps, :geojson_cache, true)
    on_exit(fn -> Application.put_env(:transitmaps, :geojson_cache, false) end)
  end

  test "keeps serving the previous response while an import's rebuild runs" do
    test = self()
    key = {:routes, [make_ref()]}
    version = start_supervised!({Agent, fn -> 1 end})

    # Background rebuilds hold for the test's go-ahead, so the window in
    # which the old response is still served can be observed.
    builder = fn ->
      if self() != test do
        send(test, {:rebuilding, self()})

        receive do
          :continue -> :ok
        end
      end

      %{version: Agent.get(version, & &1)}
    end

    first = GeoJsonCache.fetch(key, builder)
    assert decode(first) == %{"version" => 1}

    Agent.update(version, fn _ -> 2 end)
    :ok = GeoJsonCache.invalidate()

    assert_receive {:rebuilding, rebuild}
    assert GeoJsonCache.fetch(key, builder) == first

    ref = Process.monitor(rebuild)
    send(rebuild, :continue)
    assert_receive {:DOWN, ^ref, :process, ^rebuild, :normal}

    assert decode(GeoJsonCache.fetch(key, builder)) == %{"version" => 2}
    refute_received {:rebuilding, _pid}
  end

  defp decode({body, _gzipped, _etag}), do: Jason.decode!(body)
end
