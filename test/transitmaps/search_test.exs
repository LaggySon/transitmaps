defmodule Transitmaps.SearchTest do
  use ExUnit.Case, async: true

  alias Transitmaps.Search

  test "ignores case and accents" do
    index = Search.index(["Île-de-France Mobilités", "Paris, France"])

    assert Search.match?(Search.words("ile de france"), index)
    assert Search.match?(Search.words("MOBILITES"), index)
    assert Search.match?(Search.words("zurich"), Search.index(["Zürich"]))
    refute Search.match?(Search.words("lyon"), index)
    refute Search.match?(Search.words("  "), index)
  end

  test "ranks whole words above word starts above anything inside a word" do
    words = Search.words("paris")

    assert Search.rank(words, Search.index(["Île-de-France Mobilités", "Paris, France"])) == 0
    assert Search.rank(words, Search.index(["Parisian Lines"])) == 1
    assert Search.rank(words, Search.index(["St. Bernard Parish"])) == 1
    assert Search.rank(words, Search.index(["Comparison Transit"])) == 2
  end
end
