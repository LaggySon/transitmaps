defmodule Transitmaps.Repo.Migrations.ReimportFeedsWithStationHops do
  use Ecto.Migration

  # The importer now cuts station-to-station hops out of shapes that
  # otherwise follow the track (NS International, DSB and GoVolta abroad,
  # rail-replacement buses). Telling a hop from straight track needs the raw
  # shape, which only a fresh download has, so every downloaded agency with a
  # segment over 5 km is queued for re-import. The worker runs them one at a
  # time; the map keeps drawing the current lines until each is replaced.

  def up do
    repo().query!(
      """
      WITH candidates AS (
        SELECT DISTINCT f.catalog_id
        FROM feeds f
        JOIN routes r ON r.feed_id = f.id
        CROSS JOIN LATERAL jsonb_array_elements(r.geometry->'coordinates') AS l(line)
        CROSS JOIN LATERAL jsonb_array_elements(l.line) WITH ORDINALITY AS p(pt, n)
        WHERE f.catalog_id IS NOT NULL
          AND r.geometry IS NOT NULL
          AND r.category NOT IN ('ferry', 'other')
          AND l.line->(p.n::int) IS NOT NULL
          AND 2 * 6371 * asin(least(1, sqrt(
            sin(radians((l.line->(p.n::int)->>1)::float - (p.pt->>1)::float) / 2) ^ 2 +
            cos(radians((p.pt->>1)::float)) * cos(radians((l.line->(p.n::int)->>1)::float)) *
            sin(radians((l.line->(p.n::int)->>0)::float - (p.pt->>0)::float) / 2) ^ 2
          ))) > 5
      )
      UPDATE feed_imports SET status = 'queued', updated_at = now()
      FROM candidates
      WHERE feed_imports.catalog_id = candidates.catalog_id AND feed_imports.status = 'ready'
      """,
      [],
      timeout: :infinity
    )
  end

  def down, do: :ok
end
