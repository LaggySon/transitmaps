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
    |> Enum.flat_map(fn {{category, agency, color}, group} ->
      group
      |> by_line_name(category, agency)
      |> Enum.map(&line(category, agency, color, &1))
    end)
    |> Enum.sort_by(&{&1.category, &1.agency, &1.name})
  end

  @split_categories ~w(rail metro tram)

  # A regional operator that colours all its trains alike (VBB's DB Regio:
  # RE1, RB23, …) would otherwise be one line named after the operator. When
  # nothing its routes share names them, each line name is drawn on its own,
  # the way riders know the network. Brand-coloured operators keep their one
  # line: Britain's operators are known by name, not by route.
  defp by_line_name(group, category, agency) do
    if category in @split_categories and brand_color(agency, category) == nil and
         line_name(category, agency, group) == agency do
      group |> Enum.group_by(&split_key/1) |> Map.values()
    else
      [group]
    end
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
    {"eurostar", "#0B2343"},
    # Amtrak's feed colours every train a pale #CAE4F1 that all but vanishes
    # on the basemap; its brand blue reads clearly along every corridor.
    {"amtrak", "#00539B"},
    # Continental operators whose feeds leave their trains uncoloured.
    {"ns international", "#7D2A82"},
    {"nederlandse spoorwegen", "#003082"},
    {"dsb s-tog", nil},
    {"dsb", "#B41730"},
    {"staatsbahnen", "#EC0016"},
    {"db fernverkehr", "#EC0016"},
    {"schweizerische bundesbahnen", "#EB0000"},
    {"arriva", "#00A3E0"},
    {"iarnród éireann", "#00843D"},
    {"irish rail", "#00843D"}
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

    # The first operator that matches decides; a nil colour (DSB's S-tog,
    # whose lines have their own) means no brand colour.
    case Enum.find(@brand_colors, fn {pattern, _color} ->
           String.contains?(normalized, pattern)
         end) do
      {_pattern, color} -> color
      nil -> exact_brand_color(normalized)
    end
  end

  def brand_color(_agency_name, _category), do: nil

  # Operators known by a name too short to search for inside others.
  defp exact_brand_color("ns"), do: "#003082"
  defp exact_brand_color(_agency), do: nil

  # Lines with colours riders know, for feeds that don't ship them:
  # {agency pattern, category, line name, colour}.
  @line_colors [
    # Berlin S-Bahn
    {"s-bahn berlin", "rail", ~w(S1), "#DA6BA2"},
    {"s-bahn berlin", "rail", ~w(S2 S25 S26), "#007734"},
    {"s-bahn berlin", "rail", ~w(S3), "#0066AD"},
    {"s-bahn berlin", "rail", ~w(S41), "#AD5937"},
    {"s-bahn berlin", "rail", ~w(S42), "#CB6418"},
    {"s-bahn berlin", "rail", ~w(S45 S46 S47), "#CD9C53"},
    {"s-bahn berlin", "rail", ~w(S5), "#EB7405"},
    {"s-bahn berlin", "rail", ~w(S7 S75), "#816DA6"},
    {"s-bahn berlin", "rail", ~w(S8 S85), "#66AA22"},
    {"s-bahn berlin", "rail", ~w(S9), "#992746"},
    # Copenhagen S-tog and Metro
    {"dsb s-tog", "rail", ~w(A), "#0098D4"},
    {"dsb s-tog", "rail", ~w(B), "#4BAF4F"},
    {"dsb s-tog", "rail", ~w(Bx), "#A5C93D"},
    {"dsb s-tog", "rail", ~w(C), "#F39200"},
    {"dsb s-tog", "rail", ~w(E), "#7C6FAB"},
    {"dsb s-tog", "rail", ~w(F), "#FFC20E"},
    {"dsb s-tog", "rail", ~w(H), "#E2001A"},
    {"metroselskabet", "metro", ~w(M1), "#00845A"},
    {"metroselskabet", "metro", ~w(M2), "#FFC20E"},
    {"metroselskabet", "metro", ~w(M3), "#E2001A"},
    {"metroselskabet", "metro", ~w(M4), "#0095DA"},
    # Dublin's Luas
    {"luas", "tram", ["Red", "Red Line"], "#E31B23"},
    {"luas", "tram", ["Green", "Green Line"], "#00A651"}
  ]

  defp line_color(%{agency_name: agency, category: category} = route)
       when is_binary(agency) do
    agency = String.downcase(agency)
    names = Enum.reject([route.short_name, route.long_name], &is_nil/1)

    Enum.find_value(@line_colors, fn {pattern, line_category, lines, color} ->
      if line_category == category and String.contains?(agency, pattern) and
           Enum.any?(names, &(&1 in lines)),
         do: color
    end)
  end

  defp line_color(_route), do: nil

  defp color(route) do
    brand_color(route.agency_name, route.category) ||
      route.color || line_color(route) || RouteTypes.default_color(route.category)
  end

  # A brand-coloured group is an operator's network and shows the operator
  # name ("CrossCountry", not its route's headcode). Everything else is
  # named the way its riders know it, from what its routes have in common,
  # and only falls back to the agency when they have nothing.
  defp line_name(category, agency, group) do
    if brand_color(agency, category) do
      agency
    else
      # Short names only name a group when every route has one.
      all_shorts = Enum.map(group, &display_short_name/1)
      shorts = if nil in all_shorts, do: [], else: Enum.uniq(all_shorts)
      # A long name with nothing to read (SNCF's " -") names nothing.
      longs =
        group
        |> Enum.map(& &1.long_name)
        |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/[\p{L}\p{N}]/u, &1)))
        |> Enum.uniq()

      shared_value(shorts) || direction_stem(shorts) || short_long_name(longs) ||
        line_prefix(longs) || joined_shorts(category, shorts) || agency
    end
  end

  # A short name riders never see: SNCF files its TGV and Intercités routes
  # under codes like "601A" (and some under "INCONNU", unknown), where the
  # long name reads "Paris - Lyon TGV". Its TER line numbers ("K5", "P53")
  # stay, and so do other operators' numbers (Lokaltog's "110R" is a line).
  @placeholder_names ~w(inconnu unknown)

  defp display_short_name(%{short_name: short} = route) when is_binary(short) do
    if code_name?(route), do: nil, else: short
  end

  defp display_short_name(_route), do: nil

  defp code_name?(%{short_name: short, agency_name: agency}) when is_binary(short) do
    String.downcase(short) in @placeholder_names or
      (String.contains?(String.downcase(agency || ""), "sncf") and
         Regex.match?(~r/^\d{3,}[A-Z]?$/, short))
  end

  defp code_name?(_route), do: false

  # The name a route is drawn under when an operator's routes are drawn one
  # line per name: its short name, or its long name when the short one is a
  # code.
  defp split_key(route) do
    if code_name?(route), do: route.long_name, else: route.short_name
  end

  defp shared_value([value]), do: value
  defp shared_value(_values), do: nil

  # One line run as a route per direction or branch: BART's "Yellow-N" and
  # "Yellow-S" are the Yellow line.
  defp direction_stem([_, _ | _] = shorts) do
    shorts
    |> Enum.map(&Regex.run(~r/^(.+?)[-_ ][A-Za-z0-9]{1,2}$/, &1, capture: :all_but_first))
    |> Enum.uniq()
    |> case do
      [[stem]] -> stem
      _stems -> nil
    end
  end

  defp direction_stem(_shorts), do: nil

  # A line its feed only names in full: CTA's and the MBTA's "Red Line".
  # Long names that run to whole sentences or termini lists don't fit a
  # label.
  defp short_long_name([long]) when byte_size(long) <= 30, do: long
  defp short_long_name(_longs), do: nil

  # Branches of one line: the MBTA's "Green Line B" to "Green Line E".
  @line_words ~w(line linie ligne línea linea lijn linja)

  defp line_prefix([_, _ | _] = longs) do
    shared_words =
      longs
      |> Enum.map(&String.split/1)
      |> Enum.zip()
      |> Enum.map(&Tuple.to_list/1)
      |> Enum.take_while(&match?([_], Enum.uniq(&1)))
      |> Enum.map(&hd/1)

    if shared_words != [] and String.downcase(List.last(shared_words)) in @line_words,
      do: Enum.join(shared_words, " ")
  end

  defp line_prefix(_longs), do: nil

  # A few subway services sharing track and colour: New York's A, C and E.
  defp joined_shorts("metro", [_, _ | _] = shorts) do
    if length(shorts) <= 4 and Enum.all?(shorts, &(String.length(&1) <= 3)),
      do: shorts |> Enum.sort() |> Enum.join(" ")
  end

  defp joined_shorts(_category, _shorts), do: nil

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
