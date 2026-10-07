defmodule Transitmaps.Catalog do
  @moduledoc """
  The world's public GTFS feeds — one per agency, more or less — from the
  Mobility Database catalog, for the map's agency search.

  The catalog is one CSV listing every known feed with its provider,
  location and a mirrored download on MobilityData's own storage, so the
  server can fetch any agency without hammering (or needing keys for) the
  agency's own site. It is downloaded once a day, cached on disk, and held
  in `:persistent_term` for reads, since every search walks it.
  """

  use GenServer
  require Logger

  alias Transitmaps.Catalog.Countries
  alias Transitmaps.Gtfs.Csv
  alias Transitmaps.Packages

  @default_source "https://files.mobilitydatabase.org/feeds_v2.csv"

  # Agencies catalogued twice under different downloads of the same data,
  # which would draw every line twice: AVV's feed with and without its stop
  # poles (mdb-1224 is kept).
  @duplicates ~w(mdb-1094)

  # Feeds whose trains the "Shape rail feeds" workflow traces along
  # OpenStreetMap's railways (.github/workflows/shape-feeds.yml), downloaded
  # from its release instead of MobilityData's mirror: national rail feeds
  # that publish no shapes, Lyon's and Eurostar's, which leave some trains
  # unshaped, Sweden's and Norway's, whose trains hop straight between
  # stations, Spain's Cercanías, whose one shape per line leaves out
  # branches, and Finland's trains, which the mirror doesn't carry.
  @shaped ~w(mdb-768 mdb-1089 tdg-83582 mdb-1859 mdb-2898 mdb-2939 mdb-1078 mdb-2653 mdb-1102 tdg-82199 tdg-81943)
  @shaped_url "https://github.com/LaggySon/transitmaps/releases/download/shaped-feeds/"

  # Names for national feeds whose catalog listing reads like a dataset
  # title ("Systemaufgaben Kundeninformation SKI+ · Switzerland Aggregate").
  @labels %{
    "mdb-768" => "Deutsche Bahn · Long-distance trains",
    "mdb-1089" => "Germany · Regional trains",
    "tdg-83582" => "SNCF · TGV, Intercités and TER",
    "mdb-1859" => "SNCB / NMBS · Belgian railways",
    "mdb-2898" => "Switzerland · SBB and every Swiss operator",
    "mdb-1102" => "VR · Finland's passenger trains"
  }
  @refresh_ms :timer.hours(24)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Agencies whose name or place contains every word of `query`, best
  matches first: provider names starting with the query, then the rest.
  """
  def search(query, limit \\ 20) do
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    if words == [] do
      []
    else
      feeds()
      |> Enum.filter(fn feed -> Enum.all?(words, &String.contains?(feed.search_text, &1)) end)
      |> Enum.sort_by(&{not String.starts_with?(String.downcase(&1.label), hd(words)), &1.label})
      |> Enum.take(limit)
    end
  end

  @doc "The catalog entry with `id`, or nil."
  def get(id), do: Enum.find(feeds(), &(&1.id == id))

  @doc "All usable catalog feeds; empty until the first load completes."
  def feeds, do: :persistent_term.get(__MODULE__, [])

  @doc "Whether the catalog has loaded, so its agencies can be looked up."
  def loaded?, do: :persistent_term.get(__MODULE__, nil) != nil

  @doc false
  def parse(path) do
    pinned = Packages.catalog_ids()

    {packed, listed} =
      path
      |> Path.dirname()
      |> Csv.stream(Path.basename(path))
      |> Stream.filter(&downloadable?/1)
      |> Stream.reject(&(&1["id"] in @duplicates))
      |> Enum.split_with(&MapSet.member?(pinned, &1["id"]))

    # A few agencies are catalogued twice under one download; a pack's
    # listing wins.
    (packed ++ Enum.filter(listed, &listed?/1))
    |> Enum.map(&feed/1)
    |> Enum.uniq_by(&(&1.source_url || &1.id))
  end

  # Static GTFS with a copy on MobilityData's mirror, or on our own release.
  defp downloadable?(row) do
    row["data_type"] == "gtfs" and (present?(row["urls.latest"]) or row["id"] in @shaped) and
      String.match?(row["location.country_code"] || "", ~r/^[A-Z]{2}$/)
  end

  # Search offers feeds that are live today and need no key at the source.
  # `Transitmaps.Packages` vouches for its members beyond that.
  defp listed?(row) do
    row["status"] in ["active", ""] and row["urls.authentication_type"] in [nil, "", "0"] and
      not known_shapeless?(row)
  end

  # The map draws only route shapes, so feeds the catalog lists as having
  # none are left out. Many feeds have no features listed at all (Amtrak's
  # does ship shapes); those are offered and checked when imported.
  defp known_shapeless?(row) do
    case presence(row["features"]) do
      nil -> false
      features -> "Shapes" not in String.split(features, "|")
    end
  end

  defp feed(row) do
    provider = presence(row["provider"]) || row["id"]

    label =
      cond do
        label = @labels[row["id"]] -> label
        presence(row["name"]) -> "#{provider} · #{row["name"]}"
        true -> provider
      end

    place =
      [
        presence(row["location.municipality"]),
        presence(row["location.subdivision_name"]),
        Countries.name(row["location.country_code"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.join(", ")

    %{
      id: row["id"],
      label: label,
      place: place,
      url:
        if(row["id"] in @shaped, do: @shaped_url <> row["id"] <> ".zip", else: row["urls.latest"]),
      source_url: presence(row["urls.direct_download"]),
      search_text: String.downcase(label <> " " <> place)
    }
  end

  defp present?(value), do: presence(value) != nil
  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value

  # -- loading -----------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:transitmaps, __MODULE__, [])
    source = Keyword.get(opts, :source, Keyword.get(config, :source, @default_source))

    cache_path =
      Keyword.get(config, :cache_path, Path.join(["priv", "gtfs_cache", "catalog.csv"]))

    {:ok, %{source: source, cache_path: cache_path}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    load(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    load(state)
    {:noreply, state}
  end

  # A local source (tests, offline development) is read directly. A remote
  # one is served from the disk cache while it is fresh, re-downloaded once
  # it is a day old, and falls back to the stale copy if the download fails.
  defp load(%{source: source, cache_path: cache_path}) do
    path =
      cond do
        not String.starts_with?(source, "http") -> source
        fresh?(cache_path) -> cache_path
        download(source, cache_path) == :ok -> cache_path
        File.exists?(cache_path) -> cache_path
        true -> nil
      end

    if path do
      feeds = parse(path)
      :persistent_term.put(__MODULE__, feeds)
      Logger.info("Feed catalog loaded: #{length(feeds)} feeds")
      Transitmaps.Agencies.Worker.poke()
    end

    if String.starts_with?(source, "http"), do: Process.send_after(self(), :refresh, @refresh_ms)
  end

  defp fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime < div(@refresh_ms, 1000)
      {:error, _} -> false
    end
  end

  defp download(source, cache_path) do
    File.mkdir_p!(Path.dirname(cache_path))
    partial = cache_path <> ".part"

    case Req.get(source, into: File.stream!(partial), raw: true, retry: :transient) do
      {:ok, %{status: 200}} ->
        File.rename!(partial, cache_path)
        :ok

      other ->
        File.rm(partial)
        Logger.warning("Feed catalog download failed: #{inspect(other, limit: 5)}")
        :error
    end
  end
end
