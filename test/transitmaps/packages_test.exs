defmodule Transitmaps.PackagesTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Packages

  test "every pack has a unique id and members listed once" do
    ids = Enum.map(Packages.all(), & &1.id)
    assert ids == Enum.uniq(ids)
    assert length(ids) >= 10

    for package <- Packages.all() do
      assert package.catalog_ids == Enum.uniq(package.catalog_ids), package.id
      assert [[west, south], [east, north]] = package.bounds
      assert west < east and south < north, package.id
    end
  end

  test "lists each region's packs together" do
    regions = Packages.all() |> Enum.map(& &1.region) |> Enum.dedup()
    assert regions == Enum.uniq(regions)
  end

  test "finds packs by name, place or the cities they cover" do
    assert [%{id: "bay-area"}] = Packages.search("bay area")
    assert [%{id: "bay-area"}] = Packages.search("Oakland")
    assert [%{id: "northeast-corridor"}] = Packages.search("philadelphia")
    assert [%{id: "france"}] = Packages.search("paris")
    assert [%{id: "canada-corridor"}] = Packages.search("montréal")
    assert [%{id: "iberia"}] = Packages.search("lisbon")
    assert [%{id: "benelux"}] = Packages.search("amsterdam")
    assert [%{id: "nordics"}] = Packages.search("oslo")
    assert Packages.search("  ") == []
  end
end
