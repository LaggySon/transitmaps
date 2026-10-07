defmodule Transitmaps.Repo.Migrations.DropDuplicateAvvFeed do
  use Ecto.Migration

  # AVV (Aachen) was downloaded twice, from two catalog listings of the same
  # data, so every line drew twice. `Transitmaps.Catalog` no longer offers
  # mdb-1094; mdb-1224 stays.
  def up do
    repo().query!("DELETE FROM feeds WHERE catalog_id = 'mdb-1094'")
    repo().query!("DELETE FROM feed_imports WHERE catalog_id = 'mdb-1094'")
  end

  def down, do: :ok
end
