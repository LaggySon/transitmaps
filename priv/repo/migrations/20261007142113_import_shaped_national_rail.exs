defmodule Transitmaps.Repo.Migrations.ImportShapedNationalRail do
  use Ecto.Migration

  # National rail feeds that publish no shapes now download traced copies
  # (see `Transitmaps.Catalog`), and their packs list them: Germany's
  # long-distance and regional trains, SNCF, SNCB and Switzerland, and
  # Sweden, whose own train shapes only join its stations. They are
  # queued, and Eurostar and Lyon are imported again from their copies, which
  # draw the trains their own feeds leave unshaped. Only a database that
  # already serves a map is queued; a fresh one (tests, development) starts
  # empty.
  @queue [
    {"mdb-768", "Deutsche Bahn · Long-distance trains"},
    {"mdb-1089", "Germany · Regional trains"},
    {"tdg-83582", "SNCF · TGV, Intercités and TER"},
    {"mdb-1859", "SNCB / NMBS · Belgian railways"},
    {"mdb-2898", "Switzerland · SBB and every Swiss operator"},
    {"mdb-2939", "Trafiklab · GTFS Sweden 3"},
    {"mdb-1102", "VR · Finland's passenger trains"},
    {"tdg-82199", "Eurostar International Ltd. · Réseau européen Eurostar"},
    {"tdg-81943", "SYTRAL Mobilités · Réseau urbain TCL"}
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
