defmodule Transitmaps.ApplicationTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Application

  test "refreshes GTFS by default only for the main Railway branch" do
    assert Application.refresh_gtfs_on_startup?(%{"RAILWAY_GIT_BRANCH" => "main"})

    refute Application.refresh_gtfs_on_startup?(%{
             "RAILWAY_GIT_BRANCH" => "feature/preview"
           })

    refute Application.refresh_gtfs_on_startup?(%{})
  end

  test "an explicit refresh setting overrides the branch default" do
    refute Application.refresh_gtfs_on_startup?(%{
             "RAILWAY_GIT_BRANCH" => "main",
             "GTFS_AUTO_REFRESH" => "false"
           })

    assert Application.refresh_gtfs_on_startup?(%{
             "RAILWAY_GIT_BRANCH" => "feature/preview",
             "GTFS_AUTO_REFRESH" => "true"
           })
  end
end
