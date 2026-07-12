defmodule Transitmaps.Repo.Migrations.CreateGtfsTables do
  use Ecto.Migration

  def change do
    create table(:feeds) do
      add :name, :string, null: false
      add :url, :string, size: 1000
      add :imported_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feeds, [:name])

    create table(:routes) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :route_id, :string, null: false
      add :agency_name, :string
      add :short_name, :string
      add :long_name, :string, size: 500
      add :route_type, :integer, null: false
      add :category, :string, null: false
      add :color, :string
      add :text_color, :string
      # GeoJSON MultiLineString coordinates: [[[lon, lat], ...], ...]
      add :geometry, :jsonb

      timestamps(type: :utc_datetime)
    end

    create unique_index(:routes, [:feed_id, :route_id])
    create index(:routes, [:category])

    create table(:stops) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :stop_id, :string, null: false
      add :name, :string, size: 500
      add :lat, :float, null: false
      add :lon, :float, null: false
      add :location_type, :integer, default: 0
      # categories of the routes serving this stop, e.g. ["rail", "metro"]
      add :categories, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stops, [:feed_id, :stop_id])
    create index(:stops, [:categories], using: :gin)
  end
end
