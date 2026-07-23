defmodule Transitmaps.Live do
  @moduledoc """
  Read side of the live vehicle layer.

  `Transitmaps.Live.Server` refreshes real-time train positions in the
  background and stores the latest GeoJSON features per region in an ETS
  table; requests read them here without going through the server process.
  """

  @table :live_vehicles
  @regions ~w(great-britain northeast-corridor)

  @doc "The ETS table name backing the live vehicle cache."
  def table, do: @table

  @doc "Known regions the live layer can serve."
  def regions, do: @regions

  @doc "Normalizes an untrusted region param, defaulting to Great Britain."
  def sanitize_region(region) when region in @regions, do: region
  def sanitize_region(_region), do: "great-britain"

  @doc "Stores the latest feature list for a region."
  def put(region, features), do: :ets.insert(@table, {region, features})

  @doc "Returns the latest live vehicles for a region as a GeoJSON FeatureCollection."
  def vehicles_geojson(region) do
    %{type: "FeatureCollection", features: features(sanitize_region(region))}
  end

  defp features(region) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        case :ets.lookup(@table, region) do
          [{^region, features}] -> features
          _ -> []
        end
    end
  end
end
