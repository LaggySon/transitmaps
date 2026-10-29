defmodule Transitmaps.Repo.Migrations.AddGeojsonResponses do
  use Ecto.Migration

  # The map's slowest GeoJSON responses, kept across restarts
  # (`Transitmaps.Gtfs.GeoJsonStore`).
  def change do
    create table(:geojson_responses, primary_key: false) do
      add :key, :binary, primary_key: true
      add :gzipped, :binary, null: false
      add :etag, :string, null: false
      add :built_at, :utc_datetime, null: false
    end

    create index(:geojson_responses, [:built_at])
  end
end
