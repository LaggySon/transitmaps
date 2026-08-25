defmodule Transitmaps.ReleaseTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Release
  alias Transitmaps.Gtfs.Feed

  test "a new or partially populated preview imports the production snapshot" do
    assert Release.preview_bootstrap_needed?([])
    assert Release.preview_bootstrap_needed?([%Feed{name: "gb-rail"}])
  end

  test "later preview deploys reuse their imported snapshot" do
    refute Release.preview_bootstrap_needed?([%Feed{name: "preview-snapshot"}])
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
