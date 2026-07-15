defmodule Transitmaps.Gtfs.OperatorColors do
  @moduledoc """
  Brand line colours for well-known National Rail operators.

  Feeds frequently ship one colour for every operator (or none at all),
  leaving corridor-sharing routes indistinguishable — Great Western and
  Southern both dark green, for instance. Known operators get their
  (approximate) brand colour by agency name instead; anything unmatched
  keeps the feed colour. Only rail-family categories are matched, so bus
  operators with rail-like names ("Southern Vectis") keep feed colours.
  """

  @rail_categories ~w(rail intercity)

  # Checked in order, so more specific names come before names they contain
  # ("great northern" before "northern"). Colours approximate each
  # operator's brand and are chosen to stay distinguishable side by side.
  @brand_colors [
    {"london north eastern", "#CE0E2D"},
    {"lner", "#CE0E2D"},
    {"great western", "#0A493E"},
    {"great northern", "#30104F"},
    {"london northwestern", "#00BF6F"},
    {"west midlands", "#FF8200"},
    {"east midlands", "#4C2F48"},
    {"south western", "#24398C"},
    {"island line", "#24398C"},
    {"southeastern", "#00AFE9"},
    {"south eastern", "#00AFE9"},
    {"gatwick express", "#EB1E2D"},
    {"stansted express", "#76232F"},
    {"heathrow express", "#532E63"},
    {"southern", "#8CC63E"},
    {"thameslink", "#E9438D"},
    {"avanti", "#004354"},
    {"caledonian sleeper", "#1D2545"},
    {"scotrail", "#002664"},
    {"transpennine", "#009DDB"},
    {"merseyrail", "#EFB700"},
    {"northern", "#262262"},
    {"transport for wales", "#E4002B"},
    {"greater anglia", "#D70926"},
    {"c2c", "#B7007C"},
    {"chiltern", "#0047BB"},
    {"crosscountry", "#660F21"},
    {"cross country", "#660F21"},
    {"grand central", "#1C1B17"},
    {"hull trains", "#DE005C"},
    {"lumo", "#2B6EF5"},
    {"elizabeth line", "#6950A1"},
    {"london overground", "#EE7C0E"},
    {"eurostar", "#0B2343"}
  ]

  @doc """
  Brand colour for `agency_name` when it names a known rail operator,
  otherwise `nil`.
  """
  def color_for(agency_name, category)

  def color_for(agency_name, category)
      when is_binary(agency_name) and category in @rail_categories do
    normalized = String.downcase(agency_name)

    Enum.find_value(@brand_colors, fn {pattern, color} ->
      if String.contains?(normalized, pattern), do: color
    end)
  end

  def color_for(_agency_name, _category), do: nil
end
