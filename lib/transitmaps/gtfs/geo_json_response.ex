defmodule Transitmaps.Gtfs.GeoJsonResponse do
  @moduledoc "A GeoJSON response kept across restarts (`Transitmaps.Gtfs.GeoJsonStore`)."

  use Ecto.Schema

  @primary_key {:key, :binary, autogenerate: false}
  schema "geojson_responses" do
    field :gzipped, :binary
    field :etag, :string
    field :built_at, :utc_datetime
  end
end
