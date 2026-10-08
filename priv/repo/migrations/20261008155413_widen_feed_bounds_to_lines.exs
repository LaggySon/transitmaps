defmodule Transitmaps.Repo.Migrations.WidenFeedBoundsToLines do
  use Ecto.Migration

  # A feed's box (which decides when the map loads it) covered only its
  # stops' 1st–99th percentile, so a line running far from the feed's
  # centre stopped drawing once the view was on its far end. The importer
  # now widens the box to every line drawn; this does the same for what is
  # already imported. Points at 0,0 are junk and skipped.
  def up do
    repo().query!(
      """
      UPDATE feeds f SET
        min_lon = LEAST(f.min_lon, b.min_lon),
        min_lat = LEAST(f.min_lat, b.min_lat),
        max_lon = GREATEST(f.max_lon, b.max_lon),
        max_lat = GREATEST(f.max_lat, b.max_lat)
      FROM (
        SELECT r.feed_id,
          min((p.pt->>0)::float) AS min_lon, min((p.pt->>1)::float) AS min_lat,
          max((p.pt->>0)::float) AS max_lon, max((p.pt->>1)::float) AS max_lat
        FROM routes r
        CROSS JOIN LATERAL jsonb_array_elements(r.geometry->'coordinates') AS l(line)
        CROSS JOIN LATERAL jsonb_array_elements(l.line) AS p(pt)
        WHERE r.geometry IS NOT NULL
          AND NOT (abs((p.pt->>0)::float) < 1 AND abs((p.pt->>1)::float) < 1)
        GROUP BY r.feed_id
      ) b
      WHERE f.id = b.feed_id
      """,
      [],
      timeout: :infinity
    )
  end

  def down, do: :ok
end
