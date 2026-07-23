defmodule TransitmapsWeb.MapLive do
  use TransitmapsWeb, :live_view

  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.RouteTypes

  @mode_groups [
    {"rail", "Rail", "hero-building-library",
     [
       {"metro", "Metro", "Underground and subway"},
       {"tram", "Tram", "Light rail and streetcar"},
       {"rail", "National Rail", "Regional and commuter rail"},
       {"intercity", "Intercity", "Long-distance and high-speed"}
     ]},
    {"road", "Road", "hero-truck",
     [
       {"bus", "Bus", "Local bus services"},
       {"coach", "Coach", "Intercity road services"}
     ]},
    {"water", "Water", "hero-globe-alt",
     [
       {"ferry", "Ferry", "Passenger boat services"}
     ]}
  ]

  @regions [
    {"great-britain", "Great Britain", "National rail, metro and local transit",
     "London · Edinburgh"},
    {"northeast-corridor", "Northeast Corridor", "Intercity and commuter connections",
     "Boston · Washington"}
  ]

  @default_enabled ~w(metro tram rail intercity ferry)
  @default_details ~w(labels stops)
  @panels ~w(explore layers)
  @details ~w(labels stops)
  @visual_counts %{
    "metro" => 62,
    "tram" => 18,
    "rail" => 2_256,
    "intercity" => 48,
    "bus" => 981,
    "coach" => 16,
    "ferry" => 9
  }
  @visual_testing Mix.env() in [:dev, :test]

  @impl true
  def mount(params, _session, socket) do
    counts =
      if params["visual_test"] == "1" and @visual_testing do
        @visual_counts
      else
        Gtfs.category_counts()
      end

    {:ok,
     socket
     |> assign(:page_title, "Transit Maps")
     |> assign(:counts, counts)
     |> assign(:sidebar_open?, true)
     |> assign(:active_panel, "explore")
     |> assign(:options_open?, false)
     |> assign(:region, "great-britain")
     |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
     |> assign(:search_message, nil)
     |> assign(:enabled, MapSet.new(@default_enabled))
     |> assign(:details, MapSet.new(@default_details))
     |> assign(:live_traffic, false)}
  end

  @impl true
  def handle_event("toggle", %{"cat" => cat}, socket) when is_binary(cat) do
    enabled = toggle_member(socket.assigns.enabled, cat)
    {:noreply, put_enabled(socket, enabled)}
  end

  def handle_event("toggle-group", %{"group" => group}, socket) do
    cats = group_categories(group, socket.assigns.counts)
    enabled = socket.assigns.enabled

    enabled =
      if cats != [] and Enum.all?(cats, &MapSet.member?(enabled, &1)) do
        Enum.reduce(cats, enabled, &MapSet.delete(&2, &1))
      else
        Enum.reduce(cats, enabled, &MapSet.put(&2, &1))
      end

    {:noreply, put_enabled(socket, enabled)}
  end

  def handle_event("toggle-detail", %{"detail" => detail}, socket) when detail in @details do
    details = toggle_member(socket.assigns.details, detail)

    {:noreply,
     socket
     |> assign(:details, details)
     |> push_event("details-changed", %{enabled: MapSet.to_list(details)})}
  end

  def handle_event("toggle-live-traffic", _params, socket) do
    live_traffic = not socket.assigns.live_traffic

    {:noreply,
     socket
     |> assign(:live_traffic, live_traffic)
     |> push_event("live-traffic-changed", %{enabled: live_traffic})}
  end

  def handle_event("region", %{"region" => region}, socket)
      when region in ~w(great-britain northeast-corridor) do
    {:noreply,
     socket
     |> assign(:region, region)
     |> assign(:options_open?, false)
     |> push_event("map-region", %{region: region})}
  end

  def handle_event("open-panel", %{"panel" => panel}, socket) when panel in @panels do
    {:noreply,
     socket
     |> assign(:active_panel, panel)
     |> assign(:sidebar_open?, true)}
  end

  def handle_event("toggle-sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_open?, &(!&1))}
  end

  def handle_event("toggle-options", _params, socket) do
    {:noreply, update(socket, :options_open?, &(!&1))}
  end

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query)
    form = to_form(%{"query" => query}, as: :search)

    if query == "" do
      {:noreply,
       assign(socket, search_form: form, search_message: "Enter a station or stop name")}
    else
      {:noreply,
       socket
       |> assign(:search_form, form)
       |> assign(:search_message, "Searching visible services…")
       |> push_event("map-search", %{query: query})}
    end
  end

  def handle_event("search-result", %{"found" => true, "name" => name}, socket) do
    {:noreply, assign(socket, :search_message, "Showing #{name}")}
  end

  def handle_event("search-result", %{"found" => false}, socket) do
    {:noreply, assign(socket, :search_message, "No matching stop in the visible layers")}
  end

  def handle_event("clear-search", _params, socket) do
    {:noreply,
     socket
     |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
     |> assign(:search_message, nil)}
  end

  defp put_enabled(socket, enabled) do
    socket
    |> assign(:enabled, enabled)
    |> push_event("categories-changed", %{enabled: MapSet.to_list(enabled)})
  end

  defp toggle_member(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  defp mode_groups, do: @mode_groups
  defp regions, do: @regions

  defp region_label(region) do
    case List.keyfind(@regions, region, 0) do
      {_id, label, _description, _places} -> label
      nil -> "Transit"
    end
  end

  defp mode_icon("metro"), do: "hero-building-office-2"
  defp mode_icon("tram"), do: "hero-arrows-right-left"
  defp mode_icon("rail"), do: "hero-map"
  defp mode_icon("intercity"), do: "hero-bolt"
  defp mode_icon("bus"), do: "hero-truck"
  defp mode_icon("coach"), do: "hero-briefcase"
  defp mode_icon("ferry"), do: "hero-globe-alt"
  defp mode_icon(_category), do: "hero-map-pin"

  defp group_categories(group, counts) do
    case List.keyfind(@mode_groups, group, 0) do
      {_id, _label, _icon, modes} ->
        for {cat, _label, _description} <- modes, Map.get(counts, cat, 0) > 0, do: cat

      nil ->
        []
    end
  end

  defp group_all_enabled?(group, counts, enabled) do
    case group_categories(group, counts) do
      [] -> false
      cats -> Enum.all?(cats, &MapSet.member?(enabled, &1))
    end
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

        <aside
          :if={@sidebar_open?}
          id="map-sidebar"
          aria-label="Transit map menu"
          class="map-sidebar absolute z-30 flex overflow-hidden border border-white/75 bg-white/84 shadow-[0_24px_70px_rgba(46,50,52,0.2)] backdrop-blur-2xl backdrop-saturate-150"
        >
          <div class="flex min-h-0 w-full flex-col">
            <header class="shrink-0 px-4 pt-4 sm:px-5 sm:pt-5">
              <div class="flex items-center gap-3">
                <div class="transit-mark" aria-hidden="true">
                  <span></span><span></span><span></span>
                </div>
                <div class="min-w-0 flex-1">
                  <h1 class="truncate text-[18px] font-bold tracking-[-0.035em] text-[#1d1d1f]">
                    Transit Maps
                  </h1>
                  <p class="mt-0.5 truncate text-[11px] font-medium text-[#76767b]">
                    {region_label(@region)} · {total_routes(@counts) |> format_count()} routes
                  </p>
                </div>
                <button
                  id="hide-map-sidebar"
                  type="button"
                  phx-click="toggle-sidebar"
                  aria-label="Hide map menu"
                  title="Hide map menu"
                  class="apple-icon-button"
                >
                  <.icon name="hero-chevron-down" class="size-[17px] sm:hidden" />
                  <.icon name="hero-chevron-left" class="hidden size-[17px] sm:block" />
                </button>
              </div>

              <.form for={@search_form} id="map-search-form" phx-submit="search" class="relative mt-4">
                <.icon
                  name="hero-magnifying-glass"
                  class="pointer-events-none absolute top-1/2 left-3.5 z-10 size-[17px] -translate-y-1/2 text-[#78787d]"
                />
                <.input
                  field={@search_form[:query]}
                  type="search"
                  aria-label="Search stations and stops"
                  placeholder="Search stations and stops"
                  autocomplete="off"
                  class="h-10 w-full rounded-xl border-0 bg-[#eeeeef]/95 py-0 pr-10 pl-10 text-[14px] font-medium tracking-[-0.01em] text-[#1d1d1f] outline-none ring-0 transition placeholder:text-[#85858a] focus:bg-white focus:ring-2 focus:ring-[#007aff]/30"
                />
                <button
                  :if={@search_form[:query].value not in [nil, ""]}
                  id="clear-map-search"
                  type="button"
                  phx-click="clear-search"
                  aria-label="Clear search"
                  class="absolute top-1/2 right-2.5 grid size-6 -translate-y-1/2 place-items-center rounded-full bg-[#8e8e93] text-white transition hover:bg-[#636366] active:scale-90"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </.form>
              <p
                :if={@search_message}
                id="map-search-message"
                class="mt-2 px-1 text-[11px] font-medium text-[#6e6e73]"
              >
                {@search_message}
              </p>

              <nav
                id="map-menu-tabs"
                aria-label="Map menu sections"
                class="mt-4 grid grid-cols-2 rounded-[10px] bg-[#e9e9eb] p-[2px]"
              >
                <button
                  :for={
                    {panel, label, icon} <- [
                      {"explore", "Explore", "hero-map-pin"},
                      {"layers", "Layers", "hero-square-3-stack-3d"}
                    ]
                  }
                  id={"map-menu-#{panel}"}
                  type="button"
                  phx-click="open-panel"
                  phx-value-panel={panel}
                  aria-current={if(@active_panel == panel, do: "page", else: "false")}
                  class={[
                    "flex h-8 items-center justify-center gap-1.5 rounded-lg text-[12px] font-semibold tracking-[-0.01em] transition duration-200 active:scale-[0.98]",
                    if(@active_panel == panel,
                      do: "bg-white text-[#1d1d1f] shadow-[0_1px_3px_rgba(0,0,0,0.16)]",
                      else: "text-[#6e6e73] hover:text-[#1d1d1f]"
                    )
                  ]}
                >
                  <.icon name={icon} class="size-3.5" />
                  {label}
                </button>
              </nav>
            </header>

            <div
              id="map-menu-content"
              class="apple-scrollbar min-h-0 flex-1 overflow-y-auto px-4 pb-4 sm:px-5"
            >
              <section :if={@active_panel == "explore"} id="explore-menu" class="pt-5">
                <div class="flex items-end justify-between px-1">
                  <div>
                    <p class="apple-eyebrow">Browse</p>
                    <h2 class="mt-1 text-[20px] font-bold tracking-[-0.04em] text-[#1d1d1f]">
                      Regions
                    </h2>
                  </div>
                  <span class="mb-0.5 inline-flex items-center gap-1.5 text-[11px] font-semibold text-[#34c759]">
                    <span class="size-1.5 rounded-full bg-[#34c759] shadow-[0_0_0_3px_rgba(52,199,89,0.12)]">
                    </span>
                    Live
                  </span>
                </div>

                <div class="mt-3 space-y-2.5">
                  <button
                    :for={{region, label, description, places} <- regions()}
                    id={"region-#{region}"}
                    type="button"
                    phx-click="region"
                    phx-value-region={region}
                    aria-pressed={to_string(@region == region)}
                    class={[
                      "region-card group relative w-full overflow-hidden rounded-2xl border p-3.5 text-left transition duration-200 active:scale-[0.985]",
                      if(@region == region,
                        do:
                          "border-[#007aff]/35 bg-[#eaf4ff] shadow-[0_5px_18px_rgba(0,122,255,0.08)]",
                        else:
                          "border-black/[0.06] bg-white/70 hover:bg-white hover:shadow-[0_5px_18px_rgba(0,0,0,0.07)]"
                      )
                    ]}
                  >
                    <span class="region-card__art" data-region={region} aria-hidden="true">
                      <span></span><span></span><span></span>
                    </span>
                    <span class="relative z-10 block pr-16">
                      <span class="flex items-center gap-1.5 text-[14px] font-bold tracking-[-0.02em] text-[#1d1d1f]">
                        {label}
                        <.icon
                          :if={@region == region}
                          name="hero-check-circle-solid"
                          class="size-4 text-[#007aff]"
                        />
                      </span>
                      <span class="mt-1 block text-[11px] font-medium leading-4 text-[#6e6e73]">
                        {description}
                      </span>
                      <span class="mt-2 block text-[10px] font-semibold tracking-wide text-[#8e8e93] uppercase">
                        {places}
                      </span>
                    </span>
                  </button>
                </div>

                <div class="mt-5 grid grid-cols-2 gap-2.5">
                  <div class="rounded-2xl border border-black/[0.05] bg-white/65 p-3.5">
                    <span class="grid size-8 place-items-center rounded-[10px] bg-[#eaf4ff] text-[#007aff]">
                      <.icon name="hero-arrows-right-left" class="size-[17px]" />
                    </span>
                    <strong class="mt-3 block text-[20px] font-bold tracking-[-0.04em] text-[#1d1d1f]">
                      {MapSet.size(@enabled)}
                    </strong>
                    <span class="mt-0.5 block text-[10px] font-semibold text-[#7c7c80]">
                      Visible modes
                    </span>
                  </div>
                  <div class="rounded-2xl border border-black/[0.05] bg-white/65 p-3.5">
                    <span class="grid size-8 place-items-center rounded-[10px] bg-[#e9f8ed] text-[#20a940]">
                      <.icon name="hero-map" class="size-[17px]" />
                    </span>
                    <strong class="mt-3 block text-[20px] font-bold tracking-[-0.04em] text-[#1d1d1f]">
                      {total_routes(@counts) |> format_count()}
                    </strong>
                    <span class="mt-0.5 block text-[10px] font-semibold text-[#7c7c80]">
                      Mapped routes
                    </span>
                  </div>
                </div>

                <button
                  id="explore-layers-shortcut"
                  type="button"
                  phx-click="open-panel"
                  phx-value-panel="layers"
                  class="mt-4 flex w-full items-center gap-3 rounded-2xl border border-black/[0.05] bg-white/65 p-3 text-left transition hover:bg-white active:scale-[0.99]"
                >
                  <span class="grid size-9 place-items-center rounded-xl bg-[#f1ecff] text-[#7357d4]">
                    <.icon name="hero-adjustments-horizontal" class="size-[18px]" />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block text-[13px] font-bold text-[#1d1d1f]">
                      Choose transit layers
                    </span>
                    <span class="mt-0.5 block text-[10px] font-medium text-[#7c7c80]">
                      Show only the services you need
                    </span>
                  </span>
                  <.icon name="hero-chevron-right" class="size-4 text-[#a4a4a8]" />
                </button>
              </section>

              <section :if={@active_panel == "layers"} id="layers-menu" class="pt-5">
                <div class="px-1">
                  <p class="apple-eyebrow">Map content</p>
                  <h2 class="mt-1 text-[20px] font-bold tracking-[-0.04em] text-[#1d1d1f]">
                    Transit layers
                  </h2>
                  <p class="mt-1 text-[11px] font-medium leading-4 text-[#77777c]">
                    Choose which services appear on the map.
                  </p>
                </div>

                <div class="mt-4 space-y-3">
                  <section
                    :for={{group, group_label, group_icon, modes} <- mode_groups()}
                    class="overflow-hidden rounded-2xl border border-black/[0.055] bg-white/70"
                  >
                    <header class="flex h-11 items-center gap-2.5 border-b border-black/[0.055] px-3.5">
                      <span class="grid size-7 place-items-center rounded-[9px] bg-[#efeff1] text-[#5b5b60]">
                        <.icon name={group_icon} class="size-4" />
                      </span>
                      <h3 class="flex-1 text-[12px] font-bold tracking-[-0.01em] text-[#3a3a3c]">
                        {group_label}
                      </h3>
                      <button
                        :if={length(group_categories(group, @counts)) > 1}
                        id={"group-toggle-#{group}"}
                        type="button"
                        phx-click="toggle-group"
                        phx-value-group={group}
                        class="rounded-lg px-2 py-1 text-[10px] font-semibold text-[#007aff] transition hover:bg-[#007aff]/[0.08] active:scale-95"
                      >
                        {if group_all_enabled?(group, @counts, @enabled),
                          do: "Hide all",
                          else: "Show all"}
                      </button>
                    </header>

                    <div>
                      <button
                        :for={{cat, label, description} <- modes}
                        id={"layer-toggle-#{cat}"}
                        type="button"
                        role="switch"
                        aria-checked={to_string(MapSet.member?(@enabled, cat))}
                        phx-click="toggle"
                        phx-value-cat={cat}
                        disabled={route_count(@counts, cat) == 0}
                        class="layer-row group flex w-full items-center gap-3 px-3.5 py-2.5 text-left transition hover:bg-black/[0.025] disabled:cursor-not-allowed disabled:opacity-35"
                      >
                        <span
                          class="grid size-8 shrink-0 place-items-center rounded-[10px] text-white shadow-[inset_0_0_0_1px_rgba(0,0,0,0.07)]"
                          style={"background: #{RouteTypes.default_color(cat)}"}
                        >
                          <.icon name={mode_icon(cat)} class="size-4" />
                        </span>
                        <span class="min-w-0 flex-1">
                          <span class="block truncate text-[12px] font-bold tracking-[-0.01em] text-[#2c2c2e]">
                            {label}
                          </span>
                          <span class="mt-0.5 block truncate text-[9px] font-medium text-[#8a8a8e]">
                            {description} · {route_count(@counts, cat) |> format_count()}
                          </span>
                        </span>
                        <span
                          class={[
                            "apple-switch relative h-[22px] w-[38px] shrink-0 rounded-full p-0.5 transition-colors duration-200",
                            if(MapSet.member?(@enabled, cat),
                              do: "bg-[#34c759]",
                              else: "bg-[#d1d1d6]"
                            )
                          ]}
                          aria-hidden="true"
                        >
                          <span class={[
                            "block size-[18px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.3)] transition-transform duration-200",
                            MapSet.member?(@enabled, cat) && "translate-x-4"
                          ]}>
                          </span>
                        </span>
                      </button>
                    </div>
                  </section>
                </div>

                <div
                  :if={@counts == %{}}
                  id="empty-feed-notice"
                  class="mt-4 rounded-2xl bg-[#fff7df] p-3.5"
                >
                  <p class="text-[11px] font-semibold leading-4 text-[#6f5813]">
                    No feeds have been imported yet. Add a GTFS feed to start drawing routes.
                  </p>
                </div>
              </section>
            </div>

            <footer class="flex h-10 shrink-0 items-center justify-between border-t border-black/[0.06] px-5 text-[9px] font-semibold tracking-[0.02em] text-[#929297]">
              <span>Live GTFS data</span>
              <span>MapLibre · OpenFreeMap</span>
            </footer>
          </div>
        </aside>

        <button
          :if={!@sidebar_open?}
          id="show-map-sidebar"
          type="button"
          phx-click="toggle-sidebar"
          aria-label="Show map menu"
          class="map-fab absolute top-4 left-4 z-30 flex h-11 items-center gap-2.5 px-3.5 sm:top-5 sm:left-5"
        >
          <span class="transit-mark transit-mark--small" aria-hidden="true">
            <span></span><span></span><span></span>
          </span>
          <span class="text-[12px] font-bold tracking-[-0.01em] text-[#2c2c2e]">Transit Maps</span>
        </button>

        <div
          id="map-control-stack"
          class="absolute top-4 right-4 z-30 flex flex-col items-end gap-2 sm:top-5 sm:right-5"
        >
          <div class="map-control-group flex overflow-hidden">
            <button
              id="map-options-button"
              type="button"
              phx-click="toggle-options"
              aria-label="Map settings"
              aria-expanded={to_string(@options_open?)}
              class={[
                "map-control-button",
                @options_open? && "text-[#007aff]"
              ]}
            >
              <.icon name="hero-square-3-stack-3d" class="size-[19px]" />
            </button>
          </div>

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

        <section
          :if={@options_open?}
          id="map-options-menu"
          aria-label="Map settings"
          class="map-popover absolute top-[4.25rem] right-4 z-40 w-[min(18rem,calc(100vw-2rem))] overflow-hidden sm:top-[4.5rem] sm:right-5"
        >
          <header class="border-b border-black/[0.06] px-4 py-3.5">
            <p class="apple-eyebrow">Appearance</p>
            <h2 class="mt-1 text-[16px] font-bold tracking-[-0.025em] text-[#1d1d1f]">
              Map settings
            </h2>
          </header>
          <div class="p-2">
            <div class="flex items-center gap-3 rounded-xl px-2.5 py-2">
              <span class="grid size-9 place-items-center rounded-xl bg-[#eaf4ff] text-[#007aff]">
                <.icon name="hero-map" class="size-[18px]" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-[12px] font-bold text-[#2c2c2e]">Transit map</span>
                <span class="mt-0.5 block text-[9px] font-medium text-[#8e8e93]">
                  Light, detailed cartography
                </span>
              </span>
              <.icon name="hero-check-circle-solid" class="size-[18px] text-[#007aff]" />
            </div>

            <div class="my-1.5 h-px bg-black/[0.06]"></div>

            <button
              :for={
                {detail, label, icon} <- [
                  {"labels", "Station names", "hero-tag"},
                  {"stops", "Stop markers", "hero-map-pin"}
                ]
              }
              id={"map-detail-#{detail}"}
              type="button"
              role="switch"
              aria-checked={to_string(MapSet.member?(@details, detail))}
              phx-click="toggle-detail"
              phx-value-detail={detail}
              class="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition hover:bg-black/[0.035]"
            >
              <span class="grid size-8 place-items-center rounded-[10px] bg-[#efeff1] text-[#5a5a5f]">
                <.icon name={icon} class="size-4" />
              </span>
              <span class="flex-1 text-[11px] font-semibold text-[#3a3a3c]">{label}</span>
              <span
                class={[
                  "apple-switch relative h-[22px] w-[38px] shrink-0 rounded-full p-0.5 transition-colors duration-200",
                  if(MapSet.member?(@details, detail), do: "bg-[#34c759]", else: "bg-[#d1d1d6]")
                ]}
                aria-hidden="true"
              >
                <span class={[
                  "block size-[18px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.3)] transition-transform duration-200",
                  MapSet.member?(@details, detail) && "translate-x-4"
                ]}>
                </span>
              </span>
            </button>

            <div class="my-1.5 h-px bg-black/[0.06]"></div>

            <button
              id="map-live-traffic"
              type="button"
              role="switch"
              aria-checked={to_string(@live_traffic)}
              phx-click="toggle-live-traffic"
              class="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition hover:bg-black/[0.035]"
            >
              <span class="grid size-8 place-items-center rounded-[10px] bg-[#e9f8ed] text-[#20a940]">
                <.icon name="hero-signal" class="size-4" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-[11px] font-semibold text-[#3a3a3c]">Live trains</span>
                <span class="mt-0.5 block text-[9px] font-medium text-[#8e8e93]">
                  Real-time positions (London Underground &amp; rail)
                </span>
              </span>
              <span
                class={[
                  "apple-switch relative h-[22px] w-[38px] shrink-0 rounded-full p-0.5 transition-colors duration-200",
                  if(@live_traffic, do: "bg-[#34c759]", else: "bg-[#d1d1d6]")
                ]}
                aria-hidden="true"
              >
                <span class={[
                  "block size-[18px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.3)] transition-transform duration-200",
                  @live_traffic && "translate-x-4"
                ]}>
                </span>
              </span>
            </button>
          </div>
        </section>

        <div
          id="map-zoom-readout"
          class="pointer-events-none absolute right-4 bottom-7 z-20 hidden rounded-lg bg-white/75 px-2 py-1 font-mono text-[9px] font-semibold text-[#6e6e73] shadow-sm backdrop-blur-md [body.playwright-visuals_&]:block"
          aria-hidden="true"
        >
          z5.5
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp route_count(counts, cat), do: Map.get(counts, cat, 0)
  defp total_routes(counts), do: counts |> Map.values() |> Enum.sum()

  defp format_count(count) when count >= 1_000 do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_count(count), do: Integer.to_string(count)
end
