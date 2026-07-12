defmodule Transitmaps.Gtfs.Route do
  use Ecto.Schema

  schema "routes" do
    field :route_id, :string
    field :agency_name, :string
    field :short_name, :string
    field :long_name, :string
    field :route_type, :integer
    field :category, :string
    field :color, :string
    field :text_color, :string
    # GeoJSON geometry object, e.g. %{"type" => "MultiLineString", "coordinates" => [...]}
    field :geometry, :map

    belongs_to :feed, Transitmaps.Gtfs.Feed

    timestamps(type: :utc_datetime)
  end
end
