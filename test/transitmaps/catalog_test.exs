defmodule Transitmaps.CatalogTest do
  # Reads the fixture catalog loaded at application start
  # (see `config/test.exs`).
  use ExUnit.Case, async: true

  alias Transitmaps.Catalog

  test "keeps only live feeds that download without a key, each download once" do
    ids = Enum.map(Catalog.feeds(), & &1.id)

    assert "mdb-9001" in ids
    refute "mdb-9003" in ids, "inactive feeds are skipped"
    refute "mdb-9004" in ids, "feeds behind an API key are skipped"
    refute "mdb-9005" in ids, "a second listing of the same download is skipped"
    refute "mdb-9006" in ids, "feeds listed as having no shapes are skipped"
    assert "mdb-9007" in ids, "feeds with no features listed are offered"
    assert "mdb-2455" in ids, "a regional pack vouches for its members behind an API key"
  end

  test "labels agencies with their provider, feed name and place" do
    assert %{label: "Town Bus · Loop", place: "Kochi Prefecture, Japan"} =
             Catalog.get("jbda-town/bus")

    assert %{place: "Boston, Massachusetts, United States"} = Catalog.get("mdb-437")
  end

  test "searches by any words of the name or place, name matches first" do
    assert [%{id: "mdb-437"}] = Catalog.search("mbta")
    assert [%{id: "mdb-437"}] = Catalog.search("boston transportation")
    assert Catalog.search("tiny") |> Enum.map(& &1.id) == ["mdb-9001"]
    assert Catalog.search("england") |> Enum.map(& &1.id) == ["mdb-9001"]
    assert Catalog.search("   ") == []
    assert Catalog.search("atlantis") == []
  end
end
