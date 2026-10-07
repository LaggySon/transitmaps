defmodule Transitmaps.Repo.Migrations.ReimportFeedsForBranches do
  use Ecto.Migration

  # Train lines were drawn from their six most-used service patterns, which
  # left out quieter branches (RER C runs 81 patterns; Transilien N and J,
  # Hamburg's and Berlin's regional lines lost branches too). The importer
  # now keeps every pattern that adds track, so every downloaded agency is
  # imported again.
  def up do
    repo().query!(
      "UPDATE feed_imports SET status = 'queued', updated_at = now() WHERE status = 'ready'"
    )
  end

  def down, do: :ok
end
