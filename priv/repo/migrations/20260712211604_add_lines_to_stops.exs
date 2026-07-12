defmodule Transitmaps.Repo.Migrations.AddLinesToStops do
  use Ecto.Migration

  def change do
    alter table(:stops) do
      add :lines, {:array, :map}, null: false, default: []
    end
  end
end
