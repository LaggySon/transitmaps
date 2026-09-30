defmodule Transitmaps.Agencies.FeedImport do
  @moduledoc """
  One agency's download from the feed catalog: waiting, running, done or
  failed. Doubles as the import queue, so a restart loses nothing.
  """

  use Ecto.Schema

  schema "feed_imports" do
    field :catalog_id, :string
    field :label, :string
    field :status, :string
    field :error, :string
    field :imported_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
