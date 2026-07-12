defmodule Transitmaps.Repo do
  use Ecto.Repo,
    otp_app: :transitmaps,
    adapter: Ecto.Adapters.Postgres
end
