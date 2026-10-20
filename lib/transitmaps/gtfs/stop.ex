defmodule Transitmaps.Gtfs.Stop do
  use Ecto.Schema

  schema "stops" do
    field :stop_id, :string
    field :name, :string
    field :lat, :float
    field :lon, :float
    field :location_type, :integer
    field :categories, {:array, :string}
    field :lines, {:array, :map}, default: []
    # The stops under a merged station marker that have departures to list.
    field :departure_ids, {:array, :integer}, virtual: true, default: []

    belongs_to :feed, Transitmaps.Gtfs.Feed

    timestamps(type: :utc_datetime)
  end
end
