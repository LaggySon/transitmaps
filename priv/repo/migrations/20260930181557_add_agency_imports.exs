defmodule Transitmaps.Repo.Migrations.AddAgencyImports do
  use Ecto.Migration

  # Names for the hand-curated feeds, shown in the map's agency list.
  @legacy_labels [
    {"gb-rail", "National Rail"},
    {"tfl", "Transport for London"},
    {"amtrak", "Amtrak"},
    {"mbta-commuter", "MBTA Commuter Rail"},
    {"mbta-rapid", "MBTA Subway"},
    {"metro-north", "Metro-North Railroad"},
    {"nyc-subway", "NYC Subway"},
    {"nj-transit-rail", "NJ Transit Rail"},
    {"path", "PATH"},
    {"septa-regional-rail", "SEPTA Regional Rail"},
    {"septa-rapid", "SEPTA Metro"},
    {"marc", "MARC Train"},
    {"baltimore-metro", "Baltimore Metro SubwayLink"},
    {"baltimore-light-rail", "Baltimore Light RailLink"},
    {"wmata-rapid", "WMATA Metrorail"}
  ]

  def up do
    alter table(:feeds) do
      add :label, :string
      add :catalog_id, :string
      # The feed's service area: its stops' 1st–99th percentile box.
      add :min_lon, :float
      add :min_lat, :float
      add :max_lon, :float
      add :max_lat, :float
    end

    create unique_index(:feeds, [:catalog_id])
    create index(:routes, [:feed_id])
    create index(:stops, [:feed_id])

    create table(:feed_imports) do
      add :catalog_id, :string, null: false
      add :label, :string, null: false
      add :status, :string, null: false
      add :error, :string, size: 1000
      add :imported_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feed_imports, [:catalog_id])

    flush()

    for {name, label} <- @legacy_labels do
      repo().query!("UPDATE feeds SET label = $1 WHERE name = $2", [label, name])
    end

    repo().query!("UPDATE feeds SET label = name WHERE label IS NULL")

    repo().query!("""
    UPDATE feeds SET min_lon = b.min_lon, min_lat = b.min_lat, max_lon = b.max_lon, max_lat = b.max_lat
    FROM (
      SELECT feed_id,
        percentile_cont(0.01) WITHIN GROUP (ORDER BY lon) AS min_lon,
        percentile_cont(0.01) WITHIN GROUP (ORDER BY lat) AS min_lat,
        percentile_cont(0.99) WITHIN GROUP (ORDER BY lon) AS max_lon,
        percentile_cont(0.99) WITHIN GROUP (ORDER BY lat) AS max_lat
      FROM stops GROUP BY feed_id
    ) AS b
    WHERE feeds.id = b.feed_id
    """)
  end

  def down do
    drop table(:feed_imports)
    drop index(:stops, [:feed_id])
    drop index(:routes, [:feed_id])
    drop index(:feeds, [:catalog_id])

    alter table(:feeds) do
      remove :label
      remove :catalog_id
      remove :min_lon
      remove :min_lat
      remove :max_lon
      remove :max_lat
    end
  end
end
