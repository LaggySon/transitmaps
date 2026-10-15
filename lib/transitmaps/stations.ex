defmodule Transitmaps.Stations do
  @moduledoc """
  Finds stations by name across every downloaded agency, so the search box
  can take a visitor to "King's Cross" or "Gare du Nord" as well as to an
  agency.

  Only stations of rail-family modes are kept: a city's bus stops would
  outnumber them a hundred to one and turn every search into a list of
  stops called "High Street". Platforms and the same station in several
  agencies' feeds collapse into one entry.

  The index lives in `:persistent_term`, so a search reads it without
  copying, and it is rebuilt when an agency lands and every hour (imports
  can run in another VM, whose broadcasts don't reach this one). With the
  index off (in tests), each search builds it in the calling process, so the
  database sandbox applies.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Transitmaps.Gtfs.Stop
  alias Transitmaps.{Agencies, Repo, Search}

  @key {__MODULE__, :index}
  # In the menu's order.
  @categories ~w(metro tram rail intercity)
  @refresh_ms :timer.hours(1)

  # Stops with one name this close together (in degrees, about 2 km) are one
  # station: its platforms, or its listings in several agencies' feeds.
  @same_place 0.02

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Stations whose name contains every word of `query`, best match first and
  then busiest first: `%{name, lat, lon, categories, lines}`.
  """
  def search(query, limit \\ 8) do
    words = Search.words(query)

    if words |> Enum.join() |> String.length() < 2 do
      []
    else
      index()
      |> Enum.filter(&Search.match?(words, &1.index))
      |> Enum.sort_by(&{Search.rank(words, &1.index), -&1.lines, &1.name})
      |> Enum.take(limit)
      |> Enum.map(&Map.delete(&1, :index))
    end
  end

  defp index do
    if enabled?(), do: :persistent_term.get(@key, []), else: build()
  end

  defp enabled? do
    Application.get_env(:transitmaps, :station_index, true) and
      Process.whereis(__MODULE__) != nil
  end

  @doc false
  def build do
    from(s in Stop,
      where: fragment("? && ?", s.categories, ^@categories) and not is_nil(s.name),
      select: {s.name, s.lat, s.lon, s.categories, fragment("cardinality(?)", s.lines)}
    )
    |> Repo.all(timeout: :timer.minutes(2))
    |> Enum.group_by(fn {name, lat, lon, _categories, _lines} ->
      {Search.fold(name), round(lat / @same_place), round(lon / @same_place)}
    end)
    |> Enum.map(fn {_key, stops} ->
      {name, lat, lon, _categories, lines} = Enum.max_by(stops, &elem(&1, 4))
      served = stops |> Enum.flat_map(&elem(&1, 3)) |> MapSet.new()

      %{
        name: name,
        lat: lat,
        lon: lon,
        categories: Enum.filter(@categories, &MapSet.member?(served, &1)),
        lines: lines,
        index: Search.index([name])
      }
    end)
  end

  @impl true
  def init(nil) do
    Agencies.subscribe()
    send(self(), :rebuild)
    {:ok, nil}
  end

  @impl true
  def handle_info(:rebuild, state) do
    rebuild()
    Process.send_after(self(), :rebuild, @refresh_ms)
    {:noreply, state}
  end

  def handle_info(:feeds_changed, state) do
    rebuild()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A changed :persistent_term makes every process scan for the old term,
  # so an unchanged index is left alone.
  defp rebuild do
    index = build()
    if index != :persistent_term.get(@key, nil), do: :persistent_term.put(@key, index)
  rescue
    error -> Logger.warning("Station index not rebuilt: #{Exception.message(error)}")
  end
end
