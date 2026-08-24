defmodule Transitmaps.Display.Identity do
  @moduledoc """
  Decides which drawn lines exist and what each looks like.

  Routes are grouped by category, canonical operator/line identity, and
  display colour — one drawn line per group. Known rail brands are recognized
  in either the agency or route name, so aliases such as "Elizabeth line" and
  "Transport for London / Elizabeth line" receive one topology pass instead
  of drawing intersecting copies. Unrelated operators remain separate.

  Display colour prefers the operator's brand colour (national-rail feeds
  usually ship one colour for everything), then the feed colour, then the
  category default. A group keeps its route name when every member shares
  it (a TfL line called "Central") and falls back to the agency name (an
  operator's many differently-named routes).
  """

  alias Transitmaps.Gtfs.RouteTypes

  @doc "One drawn-line map per route group, in stable display order."
  def lines(routes) do
    routes
    |> Enum.group_by(fn route -> {route.category, identity(route), color(route)} end)
    |> Enum.map(fn {{category, identity, color}, group} ->
      line(category, group_agency(identity, group), color, group)
    end)
    |> Enum.sort_by(&{&1.category, &1.agency, &1.name})
  end

  defp identity(route) do
    case brand_match(route.short_name, route.category) ||
           brand_match(route.agency_name, route.category) do
      {pattern, _color} -> {:brand, pattern}
      nil -> {:agency, route.agency_name}
    end
  end

  defp group_agency({:agency, agency}, _group), do: agency

  defp group_agency({:brand, pattern}, group) do
    group
    |> Enum.map(& &1.agency_name)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.min_by(
      fn agency ->
        normalized = String.downcase(agency)
        {not String.contains?(normalized, pattern), String.length(agency), agency}
      end,
      fn -> Enum.find_value(group, & &1.short_name) || pattern end
    )
  end

  defp line(category, agency, color, group) do
    %{
      id: group |> Enum.map(& &1.route_id) |> Enum.min(),
      category: category,
      agency: agency,
      name: line_name(category, agency, group),
      long_name: shared(group, & &1.long_name),
      color: color,
      text_color: shared(group, & &1.text_color) || "#FFFFFF",
      geometry: %{
        type: "MultiLineString",
        coordinates: Enum.flat_map(group, &strands(&1.geometry))
      }
    }
  end

  # Checked in order, so more specific names come before names they
  # contain ("great northern" before "northern"). Colours approximate each
  # operator's brand and stay distinguishable side by side.
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

  # Only rail-family categories take brand colours, so bus operators with
  # rail-like names ("Southern Vectis") keep their feed colours.
  @brand_categories ~w(rail intercity)

  @doc """
  Brand colour for `agency_name` when it names a known rail operator,
  otherwise nil.
  """
  def brand_color(agency_name, category)

  def brand_color(agency_name, category)
      when is_binary(agency_name) and category in @brand_categories do
    case brand_match(agency_name, category) do
      {_pattern, color} -> color
      nil -> nil
    end
  end

  def brand_color(_agency_name, _category), do: nil

  defp brand_match(name, category)

  defp brand_match(name, category)
       when is_binary(name) and category in @brand_categories do
    normalized = String.downcase(name)
    Enum.find(@brand_colors, fn {pattern, _color} -> String.contains?(normalized, pattern) end)
  end

  defp brand_match(_name, _category), do: nil

  defp color(route) do
    brand_color(route.agency_name, route.category) ||
      route.color || RouteTypes.default_color(route.category)
  end

  # A brand-coloured group is an operator's network and shows the operator
  # name ("CrossCountry", not its route's headcode); everything else keeps
  # its route name when all members share it (a TfL line called "Central").
  defp line_name(category, agency, group) do
    if brand_color(agency, category) do
      agency
    else
      shared(group, & &1.short_name) || agency
    end
  end

  # The single value every route in the group shares, or nil when members
  # disagree (the caller then falls back to something group-wide).
  defp shared(group, fun) do
    case group |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [value] -> value
      _values -> nil
    end
  end

  defp strands(%{"type" => "MultiLineString", "coordinates" => strands}), do: strands
  defp strands(%{type: "MultiLineString", coordinates: strands}), do: strands
  defp strands(_geometry), do: []
end
