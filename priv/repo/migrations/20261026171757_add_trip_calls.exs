defmodule Transitmaps.Repo.Migrations.AddTripCalls do
  use Ecto.Migration

  # A departure opens to its whole run: every trip's calls, in buckets of
  # about 256 trips, each packed into one binary
  # (`Transitmaps.Gtfs.Timetable.trip/2`). `trip_buckets` is how many
  # buckets the feed's trips were hashed into.
  def up do
    alter table(:feeds) do
      add :trip_buckets, :integer
    end

    create table(:trip_calls, primary_key: false) do
      add :feed_id, references(:feeds, on_delete: :delete_all), primary_key: true
      add :bucket, :integer, primary_key: true
      add :calls, :binary, null: false
    end

    flush()

    # Every downloaded agency is imported again to keep its trips.
    repo().query!(
      "UPDATE feed_imports SET status = 'queued', updated_at = now() WHERE status = 'ready'"
    )
  end

  def down do
    drop table(:trip_calls)

    alter table(:feeds) do
      remove :trip_buckets
    end
  end
end
