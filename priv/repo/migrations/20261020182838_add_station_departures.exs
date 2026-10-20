defmodule Transitmaps.Repo.Migrations.AddStationDepartures do
  use Ecto.Migration

  # Stations now keep their timetable: every departure in the few weeks
  # after an import, packed into one binary per station
  # (`Transitmaps.Gtfs.Timetable`). Departures are read in the feed's own
  # time zone, counted in days from `timetable_from`.
  def up do
    alter table(:feeds) do
      add :timezone, :string
      add :timetable_from, :date
    end

    create table(:stop_departures, primary_key: false) do
      add :stop_id, references(:stops, on_delete: :delete_all), primary_key: true
      add :departures, :binary, null: false
    end

    flush()

    # Every downloaded agency is imported again to read its timetable.
    repo().query!(
      "UPDATE feed_imports SET status = 'queued', updated_at = now() WHERE status = 'ready'"
    )
  end

  def down do
    drop table(:stop_departures)

    alter table(:feeds) do
      remove :timezone
      remove :timetable_from
    end
  end
end
