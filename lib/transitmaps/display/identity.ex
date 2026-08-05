defmodule Transitmaps.Display.Identity do
  @moduledoc """
  Decides which drawn lines exist and what each looks like.

  Routes are grouped by `{category, agency, display colour}` — one drawn
  line per group. That granularity gives exactly the map Apple draws for
  Britain: every TfL-style line is its own drawn line (each has its own
  colour under one agency), while a national-rail operator's dozens of
  timetabled routes — all sharing the operator's brand colour — collapse
  into one line for the operator's whole network.

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
    |> Enum.group_by(fn route -> {route.category, route.agency_name, color(route)} end)
    |> Enum.map(fn {{category, agency, color}, group} -> line(category, agency, color, group) end)
    |> merge_same_name()
    |> Enum.sort_by(&{&1.category, &1.agency, &1.name})
  end

  # Named services, where one operator writing its own name two ways in a feed
  # is the likely cause of two drawn lines sharing a name. Bus route names are
  # not distinctive — half the operators in the country run a route "1" — so
  # buses and coaches keep whatever the grouping gave them.
  @named_categories ~w(rail intercity metro tram)

  # Two drawn lines of the same name in the same category are one service that
  # the feed described twice: an operator arriving under two agency spellings,
  # or with a brand colour on some of its routes and the feed's colour on the
  # rest. Drawn, they are two bands of a corridor with one name repeated across
  # it — "Mildmay · Suffragette · Mildmay" — and a passenger counting lines on
  # a ribbon counts one too many.
  #
  # The survivor keeps the brand-coloured group's identity where there is one,
  # since that is the operator the colour was chosen for, and otherwise the
  # group carrying the most track.
  defp merge_same_name(lines) do
    lines
    |> Enum.group_by(fn line ->
      if line.category in @named_categories,
        do: {line.category, line.name},
        else: {:kept_apart, line.id}
    end)
    |> Enum.map(fn
      {_key, [only]} -> only
      {_key, group} -> merge(group)
    end)
  end

  defp merge(group) do
    primary =
      Enum.min_by(group, fn line ->
        branded? = if brand_color(line.agency, line.category), do: 0, else: 1
        {branded?, -length(line.geometry.coordinates), line.id}
      end)

    %{
      primary
      | id: group |> Enum.map(& &1.id) |> Enum.min(),
        geometry: %{
          type: "MultiLineString",
          coordinates: group |> Enum.sort_by(& &1.id) |> Enum.flat_map(& &1.geometry.coordinates)
        }
    }
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
  # contain ("great northern" before "northern").
  #
  # Colours approximate each operator's brand, then are pulled apart until no
  # two are closer than about 14 ΔE — roughly what two bands three pixels wide
  # with white between them need before they read as two colours rather than
  # one. Nine of these are off-brand for that reason, lightness and saturation
  # moved with the hue held: West Midlands away from London Overground's orange
  # and Northern away from ScotRail's navy matter most, since each pair shares
  # track. Asking for the ~22 that would let you name a line from a legend is
  # not satisfiable across thirty brand-constrained hues — it turns navy into
  # royal blue and red into pink, and buys nothing the label does not.
  @brand_colors [
    {"london north eastern", "#CE0E2D"},
    {"lner", "#CE0E2D"},
    {"great western", "#0A493E"},
    {"great northern", "#30104F"},
    {"london northwestern", "#00BF6F"},
    {"west midlands", "#F89C3D"},
    {"east midlands", "#4C2F48"},
    {"south western", "#24398C"},
    {"island line", "#24398C"},
    {"southeastern", "#00AFE9"},
    {"south eastern", "#00AFE9"},
    {"gatwick express", "#EA1726"},
    {"stansted express", "#76232F"},
    {"heathrow express", "#532E63"},
    {"southern", "#8CC63E"},
    {"thameslink", "#E9438D"},
    {"avanti", "#004354"},
    {"caledonian sleeper", "#111523"},
    {"scotrail", "#002664"},
    {"transpennine", "#0087BC"},
    {"merseyrail", "#EFB700"},
    {"northern", "#14113D"},
    {"transport for wales", "#A80625"},
    {"greater anglia", "#FF2E4B"},
    {"c2c", "#B7007C"},
    {"chiltern", "#0047BB"},
    {"crosscountry", "#4D0917"},
    {"cross country", "#4D0917"},
    {"grand central", "#1D1C16"},
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
    normalized = String.downcase(agency_name)

    Enum.find_value(@brand_colors, fn {pattern, color} ->
      if String.contains?(normalized, pattern), do: color
    end)
  end

  def brand_color(_agency_name, _category), do: nil

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
