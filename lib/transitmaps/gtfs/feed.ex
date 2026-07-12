defmodule Transitmaps.Gtfs.Feed do
  use Ecto.Schema

  schema "feeds" do
    field :name, :string
    field :url, :string
    field :imported_at, :utc_datetime

    has_many :routes, Transitmaps.Gtfs.Route
    has_many :stops, Transitmaps.Gtfs.Stop

    timestamps(type: :utc_datetime)
  end
end
