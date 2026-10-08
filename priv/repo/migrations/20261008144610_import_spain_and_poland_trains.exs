defmodule Transitmaps.Repo.Migrations.ImportSpainAndPolandTrains do
  use Ecto.Migration

  # Renfe's high-speed and long-distance trains, Portugal's (CP) and
  # Lombardy's (Trenord), all traced along OpenStreetMap, and Poland's
  # every-operator train feed join their packs, and Norway's
  # trains, traced on a rail map that lacked Norway, are imported again.
  # Only a database that already serves a map is queued.
  @queue [
    {"mdb-2620", "Renfe · High-speed, long and medium-distance trains"},
    {"mdb-3191", "Poland · Every train operator"},
    {"mdb-1078", "Entur · Norway Aggregated"},
    {"mdb-2057", "CP · Comboios de Portugal"},
    {"mdb-855", "Trenord · Lombardy's trains"}
  ]

  def up do
    for {catalog_id, label} <- @queue do
      repo().query!(
        """
        INSERT INTO feed_imports (catalog_id, label, status, inserted_at, updated_at)
        SELECT $1, $2, 'queued', now(), now() WHERE EXISTS (SELECT 1 FROM feeds)
        ON CONFLICT (catalog_id) DO UPDATE SET status = 'queued', error = NULL, updated_at = now()
        """,
        [catalog_id, label]
      )
    end
  end

  def down, do: :ok
end
