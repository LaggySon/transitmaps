defmodule Transitmaps.Repo.Migrations.RetryFailedAgencyImports do
  use Ecto.Migration

  # Downloads that failed for reasons now fixed: imports run at boot before
  # the catalog loaded ("no longer in the catalog": Norway, Sweden, Helsinki,
  # TEC), zips with a web page appended or a BOM ahead of a quoted header
  # (Metro Bilbao, SamTrans, ACE, SMART, OCTA), and one-off failures
  # (Munich, Vienna, Nice). Feeds refused for their shapes stay failed.
  def up do
    repo().query!("""
    UPDATE feed_imports SET status = 'queued', error = NULL, updated_at = now()
    WHERE status = 'failed'
      AND (error IS NULL OR error NOT LIKE '%shapes%')
    """)
  end

  def down, do: :ok
end
