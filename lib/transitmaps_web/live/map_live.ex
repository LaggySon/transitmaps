defmodule TransitmapsWeb.MapLive do
  use TransitmapsWeb, :live_view

  # Points of interest come from the basemap's own `poi` vector layer. Which
  # OSM classes belong to a group is a rendering concern and lives in
  # `assets/js/map_places.js`.
  #
  # The colours are deliberately deeper and greyer than the transit palette —
  # places should read as basemap detail and never compete with a line colour.
  @place_groups [
    {"food", "Food & Drink", "#C2571A"},
    {"shopping", "Shopping", "#9C4A93"},
    {"culture", "Culture", "#2F6F9F"},
    {"outdoors", "Outdoors", "#3F7D4E"},
    {"essentials", "Essentials", "#6B6B72"}
  ]

  @default_enabled ~w(metro tram rail intercity ferry)
  @default_details ~w(labels stops)
  @place_ids for {id, _label, _color} <- @place_groups, do: id
  @visual_testing Mix.env() in [:dev, :test]

  @impl true
  def mount(params, _session, socket) do
    places =
      if @visual_testing and params["visual_test"] == "1" and params["visual_no_places"] == "1",
        do: MapSet.new(),
        else: MapSet.new(@place_ids)

    {:ok,
     socket
     |> assign(:page_title, "Transit Maps")
     |> assign(:region, "great-britain")
     |> assign(:enabled, MapSet.new(@default_enabled))
     |> assign(:details, MapSet.new(@default_details))
     |> assign(:places, places)
     |> assign(:live_traffic, false)}
  end

  # The live zoom readout is a debugging aid, so it stays out of production but
  # is always on while developing; the visual suite forces it on via a body
  # class so approved screenshots record the zoom they were taken at.
  defp zoom_readout?, do: @visual_testing

  # The hook paints each pin in its group's colour, so the catalogue travels to
  # the client rather than the palette being restated in JavaScript.
  defp place_catalog do
    for {id, label, color} <- @place_groups, do: %{id: id, label: label, color: color}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="transit-explorer"
        class="relative h-dvh min-h-[32rem] w-screen overflow-hidden bg-[#e9ece8] text-[#1d1d1f]"
      >
        <div
          id="transit-map"
          phx-hook="TransitMap"
          phx-update="ignore"
          data-enabled={Jason.encode!(MapSet.to_list(@enabled))}
          data-details={Jason.encode!(MapSet.to_list(@details))}
          data-places={Jason.encode!(MapSet.to_list(@places))}
          data-place-catalog={Jason.encode!(place_catalog())}
          data-live-traffic={to_string(@live_traffic)}
          data-region={@region}
          aria-label="Interactive transit map"
          class="!absolute inset-0"
        >
          <div class="map-loading pointer-events-none absolute inset-0 z-10 grid place-items-center bg-[#f3f2ee] transition-opacity duration-500">
            <div
              role="status"
              aria-live="polite"
              class="flex min-w-64 items-start gap-3 rounded-2xl border border-white/80 bg-white/88 px-4 py-3.5 shadow-[0_12px_40px_rgba(0,0,0,0.12)] backdrop-blur-xl"
            >
              <span class="map-loading__spinner size-5 rounded-full border-2 border-[#007aff]/20 border-t-[#007aff]">
              </span>
              <div class="min-w-0 flex-1">
                <p
                  data-loading-label
                  class="text-[13px] font-semibold tracking-[-0.01em] text-[#3a3a3c]"
                >
                  Loading map
                </p>
                <p data-loading-detail class="mt-0.5 text-[11px] font-medium text-[#77777c]">
                  Preparing basemap
                </p>
                <div
                  data-loading-progress
                  role="progressbar"
                  aria-label="Transit data loading progress"
                  aria-valuemin="0"
                  aria-valuemax="100"
                  class="map-loading__progress mt-2"
                >
                  <span
                    data-loading-bar
                    class="map-loading__bar map-loading__bar--indeterminate"
                  >
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div
          id="map-control-stack"
          class="absolute top-4 right-4 z-30 flex flex-col items-end gap-2 sm:top-5 sm:right-5"
        >
          <div class="map-control-group hidden overflow-hidden sm:flex">
            <button
              id="map-zoom-in"
              type="button"
              phx-click={JS.dispatch("map:zoom-in", to: "#transit-map")}
              aria-label="Zoom in"
              class="map-control-button border-b border-black/[0.08]"
            >
              <.icon name="hero-plus" class="size-[18px]" />
            </button>
            <button
              id="map-zoom-out"
              type="button"
              phx-click={JS.dispatch("map:zoom-out", to: "#transit-map")}
              aria-label="Zoom out"
              class="map-control-button"
            >
              <.icon name="hero-minus" class="size-[18px]" />
            </button>
          </div>

          <button
            id="map-locate"
            type="button"
            phx-click={JS.dispatch("map:locate", to: "#transit-map")}
            aria-label="Go to my location"
            class="map-fab grid size-10 place-items-center text-[#007aff]"
          >
            <.icon name="hero-paper-airplane-solid" class="size-[17px] -rotate-45" />
          </button>
        </div>

        <div
          id="map-zoom-readout"
          class={[
            "pointer-events-none absolute right-4 bottom-7 z-20 rounded-lg bg-white/75 px-2 py-1 font-mono text-[9px] font-semibold text-[#6e6e73] shadow-sm backdrop-blur-md",
            if(zoom_readout?(), do: "block", else: "hidden [body.playwright-visuals_&]:block")
          ]}
          aria-hidden="true"
        >
          z5.5
        </div>
      </div>
    </Layouts.app>
    """
  end
end
