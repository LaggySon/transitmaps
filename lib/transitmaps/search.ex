defmodule Transitmaps.Search do
  @moduledoc """
  How the agency search matches and ranks text, shared by the catalog, the
  regional packs and the agencies already on the map.

  Matching ignores case and accents ("zurich" finds "Zürich", "ile de
  france" finds "Île-de-France"). Every word of the query has to appear in
  the text. Results whose words match whole come first, then those where a
  word only starts one ("paris" in "Parisian"), then those where it only
  sits inside one ("paris" in "Parish").
  """

  @doc "The query's words, folded for matching."
  def words(query) when is_binary(query) do
    query |> fold() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  def words(_query), do: []

  @doc """
  The searchable form of `texts`: folded text and its words, to keep
  alongside the entry so a search doesn't fold it again.
  """
  def index(texts) do
    text = texts |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> fold()
    {text, String.split(text, ~r/[^\p{L}\p{N}]+/u, trim: true)}
  end

  @doc "Whether every query word appears in the indexed text."
  def match?([], _index), do: false
  def match?(words, {text, _words}), do: Enum.all?(words, &String.contains?(text, &1))

  @doc "Lower is better: how closely the query's words match the text's words."
  def rank(words, {_text, text_words}) do
    Enum.sum_by(words, fn word ->
      cond do
        word in text_words -> 0
        Enum.any?(text_words, &String.starts_with?(&1, word)) -> 1
        true -> 2
      end
    end)
  end

  @doc "Lowercase, without accents."
  def fold(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end
end
