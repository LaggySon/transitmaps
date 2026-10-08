defmodule Transitmaps.Agencies do
  @moduledoc """
  The transit agencies on the map, and downloading more of them on demand.

  Every imported feed is an agency the map can draw, wherever its stops are:
  the map loads the ones whose service area overlaps what is on screen. A
  visitor adds an agency by finding it in the `Transitmaps.Catalog`; the
  import is queued, and `Transitmaps.Agencies.Worker` downloads queued
  agencies one at a time from MobilityData's mirror into the database.
  After that every visitor reads it from this server, and it refreshes
  weekly. Progress is broadcast so every open map shows it live.

  Some hand-curated feeds are partial copies of an agency the catalog has
  in full (the MBTA's subway alone, say). Downloading the catalog agency
  replaces them, so the same trains are never drawn twice.
  """

  import Ecto.Query
  require Logger

  alias Transitmaps.Agencies.FeedImport
  alias Transitmaps.Catalog
  alias Transitmaps.Gtfs.{Feed, GeoJsonCache, Importer, Route}
  alias Transitmaps.{Packages, Repo}

  @topic "agencies"

  # Downloads are anonymous, so the queue is bounded: past this many waiting
  # agencies, new requests are turned away until it drains.
  @max_queued 10

  @stale_after_days 7

  # Beyond this a feed is too big to import safely in the web VM's memory.
  # Measured peaks (whole VM): Paris 133 MB zip, 420 MB; the Netherlands
  # 239 MB, 546 MB; Norway 580 MB, 881 MB; Sweden 644 MB, 607 MB.
  @max_download_bytes 700 * 1024 * 1024

  # Hand-curated feeds each catalog agency replaces once downloaded. PATH
  # stays hand-curated: the catalog's PATH feed is inactive. WMATA's needs an
  # API key at the source, but the Northeast Corridor pack vouches for the
  # mirrored copy.
  @supersedes %{
    "mdb-1847" => ~w(wmata-rapid),
    "mdb-11" => ~w(amtrak),
    "mdb-437" => ~w(mbta-commuter mbta-rapid),
    "mdb-502" => ~w(septa-rapid),
    "mdb-503" => ~w(septa-regional-rail),
    "mdb-468" => ~w(marc),
    "mdb-469" => ~w(baltimore-light-rail),
    "mdb-470" => ~w(baltimore-metro),
    "mdb-509" => ~w(nj-transit-rail),
    "mdb-516" => ~w(nyc-subway),
    "mdb-524" => ~w(metro-north),
    # Poland's every-operator feed carries Koleje Mazowieckie's trains.
    "mdb-3191" => ~w(catalog-mdb-1011)
  }

  @doc """
  Every agency the map can draw: `%{id, label, bounds, counts}`, where
  `bounds` is `[[west, south], [east, north]]` and `counts` maps each mode
  to its route count.
  """
  def list_feeds do
    counts =
      from(r in Route,
        group_by: [r.feed_id, r.category],
        select: {r.feed_id, r.category, count(r.id)}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_feed, category, count} -> {category, count} end)

    from(f in Feed, where: not is_nil(f.min_lon), order_by: f.label)
    |> Repo.all()
    |> Enum.map(fn feed ->
      %{
        id: feed.id,
        label: feed.label || feed.name,
        catalog_id: feed.catalog_id,
        bounds: [[feed.min_lon, feed.min_lat], [feed.max_lon, feed.max_lat]],
        counts: feed.id |> then(&Map.get(counts, &1, [])) |> Map.new()
      }
    end)
  end

  @doc "Import records for `catalog_ids`, keyed by catalog id."
  def imports(catalog_ids) do
    from(i in FeedImport, where: i.catalog_id in ^catalog_ids)
    |> Repo.all()
    |> Map.new(&{&1.catalog_id, &1})
  end

  @doc "The import record for `catalog_id`, or nil if it was never requested."
  def get_import(catalog_id), do: Repo.get_by(FeedImport, catalog_id: catalog_id)

  @doc """
  Queues a download of catalog agency `catalog_id`. One already waiting or
  running is left as it is. Returns `{:ok, import}`, or `{:error, reason}`
  with `:unknown` or `:busy`.
  """
  def request(catalog_id) do
    case {Catalog.get(catalog_id), get_import(catalog_id)} do
      {nil, _import} ->
        {:error, :unknown}

      {_entry, %FeedImport{status: status} = existing} when status in ~w(queued importing) ->
        {:ok, existing}

      {entry, existing} ->
        if queued_count() >= @max_queued, do: {:error, :busy}, else: queue(entry, existing)
    end
  end

  @doc """
  The `Transitmaps.Packages` packs, each listing only the members the
  catalog currently offers.
  """
  def packages do
    for package <- Packages.all() do
      %{package | catalog_ids: Enum.filter(package.catalog_ids, &Catalog.get/1)}
    end
  end

  @doc """
  Queues every agency in pack `package_id` that isn't downloaded or on its
  way. A pack is one request: it is turned away when the queue is full, but
  otherwise queues all its members at once. Returns `{:ok, imports}`, or
  `{:error, reason}` with `:unknown` or `:busy`.
  """
  def request_package(package_id) do
    case Enum.find(packages(), &(&1.id == package_id)) do
      nil ->
        {:error, :unknown}

      package ->
        if queued_count() >= @max_queued,
          do: {:error, :busy},
          else: {:ok, queue_package(package)}
    end
  end

  defp queue_package(package) do
    existing = imports(package.catalog_ids)

    for catalog_id <- package.catalog_ids,
        not match?(
          %FeedImport{status: s} when s in ~w(queued importing ready),
          existing[catalog_id]
        ) do
      {:ok, feed_import} = queue(Catalog.get(catalog_id), existing[catalog_id])
      feed_import
    end
  end

  defp queued_count do
    Repo.aggregate(from(i in FeedImport, where: i.status == "queued"), :count)
  end

  defp queue(entry, existing) do
    now = DateTime.utc_now(:second)
    attrs = %{label: entry.label, status: "queued", error: nil, updated_at: now}

    feed_import =
      case existing do
        nil ->
          # Two visitors can add the same agency at once; the second one's
          # request simply queues it again.
          Repo.insert!(
            struct(FeedImport, Map.merge(attrs, %{catalog_id: entry.id, inserted_at: now})),
            on_conflict: {:replace, [:label, :status, :error, :updated_at]},
            conflict_target: :catalog_id,
            returning: true
          )

        %FeedImport{} ->
          existing |> Ecto.Changeset.change(attrs) |> Repo.update!()
      end

    broadcast({:import_updated, feed_import})
    Transitmaps.Agencies.Worker.poke()
    {:ok, feed_import}
  end

  @doc "The longest-waiting queued download, if any."
  def next_queued do
    Repo.one(from i in FeedImport, where: i.status == "queued", order_by: i.updated_at, limit: 1)
  end

  @doc "Requeues downloads a restart cut short."
  def requeue_interrupted do
    Repo.update_all(from(i in FeedImport, where: i.status == "importing"),
      set: [status: "queued"]
    )
  end

  @doc "Queues a refresh of every agency downloaded more than a week ago."
  def queue_stale do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@stale_after_days, :day)

    Repo.update_all(
      from(i in FeedImport, where: i.status == "ready" and i.imported_at < ^cutoff),
      set: [status: "queued"]
    )
  end

  @doc """
  Downloads and imports catalog agency `catalog_id`, then retires any
  hand-curated feed it replaces.
  """
  def run_import(catalog_id) do
    update_import(catalog_id, status: "importing")

    case Catalog.get(catalog_id) do
      nil -> mark_failed(catalog_id, "This agency is no longer in the catalog")
      entry -> import_entry(entry)
    end

    :ok
  end

  defp import_entry(entry) do
    # The name doubles as a download and extraction path, so only
    # filename-safe characters survive.
    name = "catalog-" <> String.replace(entry.id, ~r/[^A-Za-z0-9_.-]/, "_")

    Importer.import_feed(name, entry.url,
      feed: %{label: entry.label, catalog_id: entry.id},
      max_bytes: @max_download_bytes,
      keep_download: false,
      invalidate: false
    )
    |> case do
      {:ok, feed} ->
        imported(entry, feed)

      {:error, :no_shapes} ->
        mark_failed(
          entry.id,
          "This agency doesn't publish route shapes that follow the track, so its lines can't be drawn"
        )

        broadcast(:feeds_changed)
    end
  rescue
    error ->
      Logger.warning("Catalog agency #{entry.id} failed: " <> Exception.message(error))
      # The reason is kept with the record (the column holds 1,000
      # characters), so a failure that only happens in production can be
      # read without its logs.
      mark_failed(
        entry.id,
        "The download couldn't be imported (#{String.slice(Exception.message(error), 0, 900)})"
      )
  end

  defp imported(entry, feed) do
    replaced = Map.get(@supersedes, entry.id, [])
    if replaced != [], do: Repo.delete_all(from f in Feed, where: f.name in ^replaced)

    GeoJsonCache.invalidate(fn
      {_kind, feed_id, _categories} -> feed_id == feed.id
      _key -> false
    end)

    update_import(entry.id, status: "ready", error: nil, imported_at: DateTime.utc_now(:second))
    broadcast(:feeds_changed)
  end

  @doc "Records that `catalog_id`'s download stopped without finishing."
  def mark_failed(catalog_id, error),
    do: update_import(catalog_id, status: "failed", error: error)

  defp update_import(catalog_id, changes) do
    changes = Keyword.put(changes, :updated_at, DateTime.utc_now(:second))
    Repo.update_all(from(i in FeedImport, where: i.catalog_id == ^catalog_id), set: changes)

    if feed_import = get_import(catalog_id), do: broadcast({:import_updated, feed_import})
  end

  @doc """
  Subscribes the caller to `{:import_updated, import}` and `:feeds_changed`.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(Transitmaps.PubSub, @topic)

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Transitmaps.PubSub, @topic, message)
end
