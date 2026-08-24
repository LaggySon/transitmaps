defmodule Transitmaps.ReleaseTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Release

  test "a new preview imports both production map feeds" do
    assert Release.missing_preview_feeds([]) == ["gb-rail", "tfl"]
  end

  test "later preview deploys import only missing feeds" do
    assert Release.missing_preview_feeds(["gb-rail"]) == ["tfl"]
    assert Release.missing_preview_feeds(["tfl"]) == ["gb-rail"]
    assert Release.missing_preview_feeds(["tfl", "gb-rail"]) == []
  end

  test "Railway applies the bootstrap only to ephemeral PR environments" do
    railway = "railway.json" |> File.read!() |> Jason.decode!()

    assert get_in(railway, ["deploy", "preDeployCommand"]) ==
             "sh /app/_build/prod/rel/transitmaps/bin/migrate"

    assert get_in(railway, ["environments", "pr", "deploy", "preDeployCommand"]) =~
             "bootstrap_preview"

    assert get_in(railway, ["environments", "pr", "deploy", "startCommand"]) =~
             "RAILWAY_SKIP_STARTUP_REFRESH=true"
  end
end
