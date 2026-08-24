defmodule Transitmaps.Display.Identity do
  @moduledoc """
  Decides which drawn lines exist and what each looks like.

  Routes are grouped by category, canonical operator/line identity, and
  display colour — one drawn line per group. Known rail brands are recognized
  in either the agency or route name, so aliases such as "Elizabeth line" and
  "Transport for London / Elizabeth line" receive one topology pass instead
  of drawing intersecting copies. Unrelated operators remain separate.

  Display colour gives named TfL rail lines their own identity, uses one
  National Rail blue for conventional train operators, then falls back to
  the feed colour and category default. A group keeps its route name when
  every member shares it (a TfL line called "Central") and falls back to the
  agency name (an operator's many differently-named routes).
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
    geometry_group = preferred_geometry_group(group, color)

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
        coordinates: Enum.flat_map(geometry_group, &strands(&1.geometry))
      }
    }
  end

  # Apple presents conventional British train operators as one calm blue
  # system. Identity still remains operator-specific so labels and station
  # service lists are accurate, but shared corridors no longer become a
  # rainbow of TOC brand colours.
  @national_rail_color "#1D4ED8"

  # Checked in order, so more specific names come before names they contain
  # ("great northern" before "northern").
  @brand_colors [
    {"london north eastern", @national_rail_color},
    {"lner", @national_rail_color},
    {"great western", @national_rail_color},
    {"great northern", @national_rail_color},
    {"london northwestern", @national_rail_color},
    {"west midlands", @national_rail_color},
    {"east midlands", @national_rail_color},
    {"south western", @national_rail_color},
    {"island line", @national_rail_color},
    {"southeastern", @national_rail_color},
    {"south eastern", @national_rail_color},
    {"gatwick express", @national_rail_color},
    {"stansted express", @national_rail_color},
    {"heathrow express", @national_rail_color},
    {"southern", @national_rail_color},
    {"thameslink", @national_rail_color},
    {"avanti", @national_rail_color},
    {"caledonian sleeper", @national_rail_color},
    {"scotrail", @national_rail_color},
    {"transpennine", @national_rail_color},
    {"merseyrail", @national_rail_color},
    {"northern", @national_rail_color},
    {"transport for wales", @national_rail_color},
    {"greater anglia", @national_rail_color},
    {"c2c", @national_rail_color},
    {"chiltern", @national_rail_color},
    {"crosscountry", @national_rail_color},
    {"cross country", @national_rail_color},
    {"grand central", @national_rail_color},
    {"hull trains", @national_rail_color},
    {"lumo", @national_rail_color},
    {"elizabeth line", "#6950A1"},
    {"london overground", "#EE7C0E"},
    {"eurostar", "#0B2343"}
  ]

  # TfL's six named Overground lines appear twice in the preview snapshot:
  # once under Transport for London and once under a line-named agency, with
  # slightly different colours. Canonical colours make both records one
  # identity before topology cleanup, so shared track and branches are
  # consolidated together.
  @named_overground_colors [
    {"liberty", "#61686B"},
    {"lioness", "#FFA600"},
    {"mildmay", "#006FE6"},
    {"suffragette", "#18A95B"},
    {"weaver", "#9B0058"},
    {"windrush", "#DC241F"}
  ]

  # Only rail-family categories take brand colours, so bus operators with
  # rail-like names ("Southern Vectis") keep their feed colours.
  @brand_categories ~w(rail intercity)

  # A named Overground line can arrive from both the official TfL import and
  # a second line-named snapshot record. Both describe the full line, so
  # unioning their slightly different shapes manufactures phantom spurs.
  # When one record carries TfL's canonical colour, use its complete geometry
  # as the authoritative copy. If no record does, retain every available
  # shape rather than dropping coverage.
  defp preferred_geometry_group(group, color) do
    named_overground? =
      Enum.any?(@named_overground_colors, fn {pattern, _canonical_color} ->
        Enum.any?(group, fn route ->
          match?({^pattern, _color}, brand_match(route.short_name, route.category))
        end)
      end)

    preferred =
      if named_overground? do
        Enum.filter(group, &same_color?(&1.color, color))
      else
        group
      end

    if preferred == [], do: group, else: preferred
  end

  defp same_color?(left, right) when is_binary(left) and is_binary(right),
    do: String.upcase(left) == String.upcase(right)

  defp same_color?(_left, _right), do: false

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

    Enum.find(@named_overground_colors, fn {pattern, _color} ->
      normalized in [pattern, "#{pattern} line"] or
        (String.contains?(normalized, "london overground") and
           String.contains?(normalized, pattern))
    end) ||
      Enum.find(@brand_colors, fn {pattern, _color} -> String.contains?(normalized, pattern) end)
  end

  defp brand_match(_name, _category), do: nil

  defp color(route) do
    brand_color(route.short_name, route.category) ||
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
