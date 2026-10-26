defmodule Transitmaps.Gtfs.Feed do
  use Ecto.Schema

  schema "feeds" do
    field :name, :string
    field :url, :string
    field :imported_at, :utc_datetime
    # What the map's agency list calls it.
    field :label, :string
    # Mobility Database id, for agencies downloaded from the catalog.
    field :catalog_id, :string
    # The service area — its stops' 1st–99th percentile box, widened to
    # every line it draws — which decides whether the map loads the feed
    # for what is on screen.
    field :min_lon, :float
    field :min_lat, :float
    field :max_lon, :float
    field :max_lat, :float
    # The agency's time zone, and the first day its stations' timetables
    # count from (`Transitmaps.Gtfs.Timetable`).
    field :timezone, :string
    field :timetable_from, :date
    # How many buckets its trips' runs are kept in (`trip_calls`), or nil
    # when they aren't kept.
    field :trip_buckets, :integer

    has_many :routes, Transitmaps.Gtfs.Route
    has_many :stops, Transitmaps.Gtfs.Stop

    timestamps(type: :utc_datetime)
  end
end
