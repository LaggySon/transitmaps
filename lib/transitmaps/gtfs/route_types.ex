defmodule Transitmaps.Gtfs.RouteTypes do
  @moduledoc """
  Maps GTFS `route_type` values (both the basic 0-12 set and the Google
  extended route types) to the display categories used for map toggles.
  """

  @categories ~w(metro tram rail intercity bus coach ferry other)

  def categories, do: @categories

  @doc "Default line color per category when the feed doesn't provide one."
  def default_color("metro"), do: "#E32017"
  def default_color("tram"), do: "#00A65F"
  def default_color("rail"), do: "#1D4ED8"
  def default_color("intercity"), do: "#7C3AED"
  def default_color("bus"), do: "#D97706"
  def default_color("coach"), do: "#B45309"
  def default_color("ferry"), do: "#0891B2"
  def default_color(_), do: "#6B7280"

  def category(route_type) when is_integer(route_type) do
    case route_type do
      0 -> "tram"
      1 -> "metro"
      2 -> "rail"
      3 -> "bus"
      4 -> "ferry"
      5 -> "tram"
      6 -> "other"
      7 -> "other"
      11 -> "bus"
      12 -> "rail"
      t when t in 101..102 -> "intercity"
      t when t in 100..117 -> "rail"
      t when t in 200..209 -> "coach"
      t when t in 400..405 -> "metro"
      t when t in 700..716 -> "bus"
      800 -> "bus"
      t when t in 900..906 -> "tram"
      t when t in [1000, 1200] -> "ferry"
      _ -> "other"
    end
  end

  def category(_), do: "other"
end
