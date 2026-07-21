defmodule Transitmaps.Gtfs.CorridorDirections do
  @moduledoc """
  Orients every strand so corridor-sharing strands run the same way.

  MapLibre's line-offset is measured to the side of the direction of
  travel, so strands drawn along the same track with opposite orientations
  offset to opposite sides of it: a drawn line whose corridor is shared by
  an opposite-running strand splits into a hollow pair of strokes instead
  of joining a tidy side-by-side fan. Per-strand endpoint normalisation
  (see `DisplayGeometry`) cannot guarantee consistency between L-shaped or
  winding routes, so this pass compares the track itself: each strand is
  fingerprinted into coarse cells with a summed travel direction per cell,
  strands sharing enough cells become neighbours scored by how aligned
  their directions are, and a greedy pass in stable order flips whole
  strands that disagree with the majority of their already-oriented
  neighbours.
  """

  alias Transitmaps.Geometry

  # ~0.4 km cells, sampled twice per cell width; neighbours need ~1.6 km of
  # shared corridor so crossings and station throats don't couple strands.
  @cell_km 0.4
  @min_shared_cells 4

  @doc """
  Returns `lines` with strand coordinate order flipped wherever needed so
  strands sharing a corridor agree on direction. Line and strand order is
  preserved; output is stable for identical input.
  """
  def align(lines) do
    strands =
      for {line, line_index} <- Enum.with_index(lines),
          {strand, strand_index} <- Enum.with_index(strand_list(line.geometry)),
          match?([_, _ | _], strand) do
        {{line_index, strand_index}, strand}
      end

    case strands do
      [] ->
        lines

      [{_id, [reference | _]} | _] ->
        scale = Geometry.km_scale(reference)
        cell_directions = Map.new(strands, fn {id, strand} -> {id, cell_directions(strand, scale)} end)
        flipped = decide_flips(Enum.map(strands, &elem(&1, 0)), cell_directions)
        rebuild(lines, flipped)
    end
  end

  # Summed unit travel direction per grid cell the strand passes through.
  # Sampling along each segment (not just vertices) keeps sparse straight
  # stretches represented in every cell they cross.
  defp cell_directions(strand, {kx, ky}) do
    strand
    |> Enum.map(fn [lon, lat] -> {lon * kx, lat * ky} end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn [{x1, y1}, {x2, y2}], cells ->
      dx = x2 - x1
      dy = y2 - y1
      length = :math.sqrt(dx * dx + dy * dy)

      if length == 0.0 do
        cells
      else
        direction = {dx / length, dy / length}
        steps = max(1, ceil(length / (@cell_km / 2)))

        Enum.reduce(0..steps, cells, fn step, acc ->
          point = {x1 + dx * step / steps, y1 + dy * step / steps}
          Map.update(acc, cell(point), direction, &add(&1, direction))
        end)
      end
    end)
  end

  defp cell({x, y}), do: {floor(x / @cell_km), floor(y / @cell_km)}

  defp add({ax, ay}, {bx, by}), do: {ax + bx, ay + by}

  defp dot({ax, ay}, {bx, by}), do: ax * bx + ay * by

  # Pairwise alignment scores between strands that share enough cells, then
  # a greedy orientation pass in stable strand order: keep the first strand
  # of each corridor component as-is and flip later strands whose summed
  # agreement with already-oriented neighbours is negative.
  defp decide_flips(ids, cell_directions) do
    scores = pair_scores(ids, cell_directions)

    neighbours =
      Enum.reduce(scores, %{}, fn {{a, b}, {shared, score}}, acc ->
        if shared >= @min_shared_cells and score != 0.0 do
          acc
          |> Map.update(a, [{b, score}], &[{b, score} | &1])
          |> Map.update(b, [{a, score}], &[{a, score} | &1])
        else
          acc
        end
      end)

    ids
    |> Enum.sort()
    |> Enum.reduce(%{}, fn id, orientation ->
      agreement =
        neighbours
        |> Map.get(id, [])
        |> Enum.reduce(0.0, fn {neighbour, score}, sum ->
          sum + score * Map.get(orientation, neighbour, 0)
        end)

      Map.put(orientation, id, if(agreement < 0.0, do: -1, else: 1))
    end)
    |> Enum.filter(fn {_id, orient} -> orient == -1 end)
    |> MapSet.new(fn {id, _orient} -> id end)
  end

  defp pair_scores(ids, cell_directions) do
    ids
    |> Enum.reduce(%{}, fn id, cell_index ->
      cell_directions[id]
      |> Map.keys()
      |> Enum.reduce(cell_index, fn cell, acc -> Map.update(acc, cell, [id], &[id | &1]) end)
    end)
    |> Enum.reduce(%{}, fn {cell, cell_ids}, scores ->
      for a <- cell_ids, b <- cell_ids, a < b, reduce: scores do
        acc ->
          contribution = dot(cell_directions[a][cell], cell_directions[b][cell])

          Map.update(acc, {a, b}, {1, contribution}, fn {shared, score} ->
            {shared + 1, score + contribution}
          end)
      end
    end)
  end

  defp rebuild(lines, flipped) do
    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, line_index} ->
      strands =
        line.geometry
        |> strand_list()
        |> Enum.with_index()
        |> Enum.map(fn {strand, strand_index} ->
          if MapSet.member?(flipped, {line_index, strand_index}) do
            Enum.reverse(strand)
          else
            strand
          end
        end)

      %{line | geometry: %{type: "MultiLineString", coordinates: strands}}
    end)
  end

  defp strand_list(%{"type" => "MultiLineString", "coordinates" => strands}), do: strands
  defp strand_list(%{type: "MultiLineString", coordinates: strands}), do: strands
  defp strand_list(_geometry), do: []
end
