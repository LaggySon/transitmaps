defmodule Transitmaps.Gtfs.OffsetSlots do
  @moduledoc """
  Assigns parallel-offset slots so corridor-sharing routes render as
  distinct side-by-side strands.

  Two routes drawn at the same offset overpaint each other; the hidden one
  then shows only as broken fragments wherever the top one deviates. Per
  category, every route gets a coarse coverage fingerprint (grid cells
  along its geometry); routes sharing a stretch of corridor are adjacent in
  an overlap graph, which is greedy-coloured in stable agency+name order.
  Colours map to slots fanning out symmetrically (0, +1, -1, +2, -2, ...),
  clamped to ±3, so corridor-sharing routes split apart into a narrow
  ribbon while isolated routes stay centred on their own track. Callers
  pass display lines (see `Transitmaps.Gtfs.group_display_lines/1`), so a
  slot means one visually distinct drawn line, not one timetabled route.
  """

  alias Transitmaps.Geometry

  # ~0.3 km fingerprint cells; adjacency needs ~2 km of shared corridor, so
  # routes that merely cross, or meet only inside one station, keep their
  # slots independent of each other.
  @cell_km 0.3
  @min_shared_cells 6

  # Widest fan allowed: slots beyond ±3 would push the outermost strands so
  # far off the track they read as separate corridors, so busier corridors
  # share the outermost slots instead of widening the ribbon further.
  @max_slot 3

  @doc """
  Returns `{route, slot}` pairs. Routes only need `category`,
  `agency_name`, `short_name`/`long_name`/`route_id`, and `geometry` keys;
  output is stable for identical input.
  """
  def assign(routes) do
    routes
    |> Enum.group_by(& &1.category)
    |> Enum.flat_map(fn {_category, group} -> assign_group(group) end)
  end

  defp assign_group(group) do
    indexed =
      group
      |> Enum.sort_by(&{&1.agency_name, &1.short_name || &1.long_name || &1.route_id})
      |> Enum.with_index()

    adjacency = corridor_adjacency(indexed)

    {slotted, _colors} =
      Enum.reduce(indexed, {[], %{}}, fn {route, index}, {slotted, colors} ->
        used =
          adjacency
          |> Map.get(index, MapSet.new())
          |> Enum.map(&colors[&1])
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        color = Enum.find(Stream.iterate(0, &(&1 + 1)), &(not MapSet.member?(used, &1)))
        {[{route, slot_for_color(color)} | slotted], Map.put(colors, index, color)}
      end)

    Enum.reverse(slotted)
  end

  # 0, +1, -1, +2, -2, ... so the ribbon stays centred on the corridor.
  defp slot_for_color(color) do
    magnitude = min(div(color + 1, 2), @max_slot)
    if rem(color, 2) == 1, do: magnitude, else: -magnitude
  end

  # Adjacency between routes that share at least @min_shared_cells of
  # corridor fingerprint, built through a cell -> routes index so only
  # actually-overlapping pairs are ever counted.
  defp corridor_adjacency(indexed) do
    scale = group_scale(indexed)

    indexed
    |> Enum.reduce(%{}, fn {route, index}, cell_routes ->
      route
      |> route_cells(scale)
      |> Enum.reduce(cell_routes, fn cell, acc ->
        Map.update(acc, cell, [index], &[index | &1])
      end)
    end)
    |> Enum.reduce(%{}, fn {_cell, route_indexes}, counts ->
      route_indexes
      |> pairs()
      |> Enum.reduce(counts, fn pair, acc -> Map.update(acc, pair, 1, &(&1 + 1)) end)
    end)
    |> Enum.reduce(%{}, fn
      {{a, b}, count}, adjacency when count >= @min_shared_cells ->
        adjacency
        |> Map.update(a, MapSet.new([b]), &MapSet.put(&1, b))
        |> Map.update(b, MapSet.new([a]), &MapSet.put(&1, a))

      _pair, adjacency ->
        adjacency
    end)
  end

  defp pairs(indexes) do
    for a <- indexes, b <- indexes, a < b, do: {a, b}
  end

  defp route_cells(route, scale) do
    route.geometry
    |> geometry_lines()
    |> Enum.reduce(MapSet.new(), fn line, cells ->
      MapSet.union(cells, Geometry.covered_cells(line, scale, @cell_km))
    end)
  end

  # One shared projection per category group so fingerprint cells from
  # different routes land on the same grid.
  defp group_scale(indexed) do
    indexed
    |> Enum.find_value(fn {route, _index} ->
      case geometry_lines(route.geometry) do
        [[point | _] | _] -> point
        _ -> nil
      end
    end)
    |> case do
      nil -> {111.320, 110.574}
      point -> Geometry.km_scale(point)
    end
  end

  defp geometry_lines(%{"type" => "MultiLineString", "coordinates" => lines}), do: lines
  defp geometry_lines(%{type: "MultiLineString", coordinates: lines}), do: lines
  defp geometry_lines(_geometry), do: []
end
