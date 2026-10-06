defmodule Transitmaps.Repo.Migrations.ReimportFeedsKeepingShortStraights do
  use Ecto.Migration

  # The importer drew too little: `DropStopToStopShapes` undrew every route
  # whose shapes only join its stops, and `ReimportFeedsWithStationHops`
  # re-imported feeds cutting every station-to-station hop over 5 km, which
  # left gaps in regional lines that run straight between stations outside
  # their own network. It now keeps those and cuts only hops over 50 km, so
  # every downloaded agency is queued to be imported again, as its weekly
  # refresh would. The map keeps drawing the current lines meanwhile.

  def up do
    repo().query!(
      "UPDATE feed_imports SET status = 'queued', updated_at = now() WHERE status = 'ready'"
    )
  end

  def down, do: :ok
end
