defmodule Transitmaps.Repo.Migrations.DropStopToStopFeeds do
  use Ecto.Migration

  # `DropStopToStopShapes` left these two feeds a few lines that pass the
  # per-route test but are straight hops too: Germany's long-distance rail
  # (gtfs.de) a couple of short border crossings, BreizhGo TER its coaches.
  # The importer now refuses a feed whose shapes mostly join its stops, which
  # can't be measured here any more (the dropped shapes are gone), so they
  # are named.
  @catalog_ids ~w(mdb-768 tdg-81474)

  @error "This agency doesn't publish route shapes that follow the track, so its lines can't be drawn"

  def up do
    repo().query!("DELETE FROM feeds WHERE catalog_id = ANY($1)", [@catalog_ids])

    repo().query!(
      "UPDATE feed_imports SET status = 'failed', error = $1, updated_at = now() WHERE catalog_id = ANY($2)",
      [@error, @catalog_ids]
    )
  end

  def down, do: :ok
end
