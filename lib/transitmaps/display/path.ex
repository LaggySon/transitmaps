defmodule Transitmaps.Display.Path do
  @moduledoc """
  A projected polyline measured once, then addressed by distance along it.

  Everything downstream of the line graph asks the same two questions of a
  piece of track: *what runs along the stretch between kilometre a and
  kilometre b*, and *where on this track is that point over there*. Answering
  either by walking the coordinate list every time is what makes a
  whole-country pass quadratic, so a path is built once with

    * `vertices` — the source coordinates paired with their distance from the
      start, at full input fidelity (nothing is resampled away), and
    * `samples` — evenly spaced probe points, each with a unit travel
      direction, used for matching and for indexing.

  Cutting is done for a whole sorted batch of positions in one traversal
  (`pieces/2`), so slicing a track into fifty edges costs one pass rather
  than fifty.
  """

  # Probe spacing. Fine enough that two lines a station throat apart are
  # matched to each other well before either drifts out of snapping range,
  # coarse enough that a country's worth of track stays a few hundred
  # thousand probes rather than millions.
  @sample_km 0.05

  @doc "Spacing between a path's probe samples, in kilometres."
  def sample_km, do: @sample_km

  @doc """
  Measures `points` (projected `{x, y}` kilometres) into a path.

  Returns `nil` for input that has no length, so callers can drop degenerate
  geometry with a single pattern match instead of guarding every use.
  """
  def new(points) do
    points = Enum.dedup(points)
    cum = cumulative(points)

    case List.last(cum) do
      nil ->
        nil

      0.0 ->
        nil

      length ->
        base = %{points: List.to_tuple(points), vertices: Enum.zip(cum, points), length: length}
        Map.put(base, :samples, sample(base))
    end
  end

  @doc "Number of probe samples on the path."
  def sample_count(path), do: tuple_size(path.samples)

  @doc "Distance along the path of probe sample `index`."
  def sample_position(path, index), do: path.samples |> elem(index) |> elem(0)

  @doc "Coordinate of probe sample `index`."
  def sample_point(path, index), do: path.samples |> elem(index) |> elem(1)

  @doc "Unit travel direction at probe sample `index`."
  def sample_direction(path, index), do: path.samples |> elem(index) |> elem(2)

  @doc """
  The pieces of `path` between consecutive `cuts`.

  `cuts` must be ascending and within `[0, length]`. `n` cuts yield `n - 1`
  point lists, each carrying every source vertex it spans plus interpolated
  endpoints, so neighbouring pieces meet exactly and no fidelity is lost at a
  cut.
  """
  def pieces(_path, cuts) when length(cuts) < 2, do: []

  def pieces(path, cuts) do
    path
    |> locate(cuts)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{start_index, start_point}, {end_index, end_point}] ->
      middle = for index <- (start_index + 1)..end_index//1, do: elem(path.points, index)

      Enum.dedup([start_point | middle] ++ [end_point])
    end)
  end

  @doc "The single piece of `path` between `from` and `to` kilometres."
  def slice(path, from, to) do
    case pieces(path, [clamp(path, from), clamp(path, to)]) do
      [piece] -> piece
      _pieces -> []
    end
  end

  defp clamp(path, position), do: position |> max(0.0) |> min(path.length)

  @doc """
  For each ascending position in `positions`, the index of the vertex it
  follows and the interpolated coordinate there — the whole batch resolved in
  one walk of the path.
  """
  def locate(path, positions), do: walk(path.vertices, 0, positions, [])

  defp walk(_vertices, _index, [], located), do: Enum.reverse(located)

  defp walk(
         [{start_km, start_point}, {end_km, end_point} | rest] = vertices,
         index,
         positions,
         located
       ) do
    [position | remaining] = positions

    if position <= end_km do
      span = end_km - start_km
      amount = if span > 0.0, do: (position - start_km) / span, else: 0.0
      point = interpolate(start_point, end_point, min(1.0, max(0.0, amount)))

      walk(vertices, index, remaining, [{index, point} | located])
    else
      walk([{end_km, end_point} | rest], index + 1, positions, located)
    end
  end

  defp walk([{_km, point}], index, positions, located) do
    positions
    |> Enum.reduce(located, fn _position, acc -> [{index, point} | acc] end)
    |> Enum.reverse()
  end

  defp sample(base) do
    count = max(1, round(base.length / @sample_km))
    positions = for step <- 0..count, do: min(base.length, step * base.length / count)
    points = base |> locate(positions) |> Enum.map(fn {_index, point} -> point end)

    [positions, points, directions(points)]
    |> Enum.zip_with(fn [position, point, direction] -> {position, point, direction} end)
    |> List.to_tuple()
  end

  defp directions([_only]), do: [{0.0, 0.0}]

  defp directions(points) do
    forward =
      points
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> unit(subtract(to, from)) end)

    forward ++ [List.last(forward)]
  end

  defp cumulative([]), do: []

  defp cumulative([first | rest]) do
    {reversed, _last} =
      Enum.reduce(rest, {[0.0], first}, fn point, {[total | _] = acc, previous} ->
        {[total + distance(previous, point) | acc], point}
      end)

    Enum.reverse(reversed)
  end

  @doc "Euclidean distance between two projected points, in kilometres."
  def distance({x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1
    :math.sqrt(dx * dx + dy * dy)
  end

  @doc "Dot product of two vectors."
  def dot({ax, ay}, {bx, by}), do: ax * bx + ay * by

  @doc "Unit vector in the direction of `vector`, or `{0.0, 0.0}` for a zero vector."
  def unit({x, y}) do
    length = :math.sqrt(x * x + y * y)
    if length == 0.0, do: {0.0, 0.0}, else: {x / length, y / length}
  end

  defp subtract({ax, ay}, {bx, by}), do: {ax - bx, ay - by}

  defp interpolate({x1, y1}, {x2, y2}, amount) do
    {x1 + (x2 - x1) * amount, y1 + (y2 - y1) * amount}
  end
end
