defmodule Transitmaps.Repo.Migrations.DropStopToStopShapes do
  use Ecto.Migration

  # Some feeds' shapes only join each route's stops with straight lines —
  # Germany's long-distance rail (gtfs.de), SNCF Transilien, Metrolink,
  # BreizhGo TER, and rail-replacement buses in several German feeds — which
  # drew straight lines across cities and countries. The importer now leaves
  # those routes undrawn (`Transitmaps.Geometry.stop_to_stop?/1`); this does
  # the same to what was already imported, with the same rule: more than
  # 1.5 km between vertices on average over at least 5 km, ferries and cable
  # cars excepted. A feed left with nothing to draw goes, as the importer
  # refuses it, and its download is marked failed.

  @error "This agency doesn't publish route shapes that follow the track, so its lines can't be drawn"

  def up do
    %{rows: rows} =
      repo().query!(
        """
        WITH segments AS (
          SELECT r.id,
            (p.pt->>0)::float AS lon1, (p.pt->>1)::float AS lat1,
            (l.line->(p.n::int)->>0)::float AS lon2, (l.line->(p.n::int)->>1)::float AS lat2
          FROM routes r
          CROSS JOIN LATERAL jsonb_array_elements(r.geometry->'coordinates') AS l(line)
          CROSS JOIN LATERAL jsonb_array_elements(l.line) WITH ORDINALITY AS p(pt, n)
          WHERE r.geometry IS NOT NULL AND r.category NOT IN ('ferry', 'other')
        ),
        lengths AS (
          SELECT id,
            sum(2 * 6371 * asin(least(1, sqrt(
              sin(radians(lat2 - lat1) / 2) ^ 2 +
              cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lon2 - lon1) / 2) ^ 2
            )))) AS km,
            count(*) AS segments
          FROM segments
          WHERE lon2 IS NOT NULL
          GROUP BY id
        )
        UPDATE routes SET geometry = NULL, updated_at = now()
        FROM lengths
        WHERE routes.id = lengths.id AND lengths.km >= 5 AND lengths.km / lengths.segments > 1.5
        RETURNING routes.feed_id
        """,
        [],
        timeout: :infinity
      )

    feed_ids = rows |> List.flatten() |> Enum.uniq()

    %{rows: emptied} =
      repo().query!(
        """
        DELETE FROM feeds f
        WHERE f.id = ANY($1)
          AND NOT EXISTS (SELECT 1 FROM routes r WHERE r.feed_id = f.id AND r.geometry IS NOT NULL)
        RETURNING f.catalog_id
        """,
        [feed_ids],
        timeout: :infinity
      )

    repo().query!(
      "UPDATE feed_imports SET status = 'failed', error = $1, updated_at = now() WHERE catalog_id = ANY($2)",
      [@error, emptied |> List.flatten() |> Enum.reject(&is_nil/1)]
    )
  end

  # The dropped geometry is gone; re-importing a feed brings back whatever
  # the importer will draw.
  def down, do: :ok
end
