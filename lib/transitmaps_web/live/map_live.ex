defmodule TransitmapsWeb.MapLive do
  use TransitmapsWeb, :live_view

  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.RouteTypes
  alias Transitmaps.Journey

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
  @panels ~w(explore layers trip)
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
     |> assign(:page_title, "Wayline")
     |> assign(:counts, counts)
     |> assign(:sidebar_open?, true)
     |> assign(:active_panel, "explore")
     |> assign(:options_open?, false)
     |> assign(:region, "great-britain")
     |> assign(:search_form, to_form(%{"query" => ""}, as: :search))
     |> assign(:search_message, nil)
     |> assign(:trip_form, to_form(%{"from" => "", "to" => ""}, as: :trip))
     |> assign(:journey, nil)
     |> assign(:journey_error, nil)
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

  def handle_event("plan-trip", %{"trip" => %{"from" => from, "to" => to}}, socket) do
    from = String.trim(from)
    to = String.trim(to)
    form = to_form(%{"from" => from, "to" => to}, as: :trip)

    case Journey.plan(from, to) do
      {:ok, itinerary} ->
        {:noreply,
         socket
         |> assign(:trip_form, form)
         |> assign(:journey, itinerary)
         |> assign(:journey_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:trip_form, form)
         |> assign(:journey, nil)
         |> assign(:journey_error, trip_error_message(reason))}
    end
  end

  def handle_event("clear-trip", _params, socket) do
    {:noreply,
     socket
     |> assign(:trip_form, to_form(%{"from" => "", "to" => ""}, as: :trip))
     |> assign(:journey, nil)
     |> assign(:journey_error, nil)}
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

  defp trip_error_message(:blank), do: "Enter a start and destination station"
  defp trip_error_message(:same_station), do: "Start and destination are the same station"
  defp trip_error_message(:no_route), do: "No connecting route in the loaded network"
  defp trip_error_message({:not_found, query}), do: "No station matching “#{query}”"
  defp trip_error_message(_reason), do: "Couldn't plan that trip"

  defp transfers_label(0), do: "Direct · no changes"
  defp transfers_label(1), do: "1 change"
  defp transfers_label(count), do: "#{count} changes"

  defp line_color(line), do: line[:color] || RouteTypes.default_color(line[:category])

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main
        id="transit-explorer"
        class="atlas-shell relative h-dvh min-h-[36rem] w-screen overflow-hidden"
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
          <div class="map-loading pointer-events-none absolute inset-0 z-10 grid place-items-center transition-opacity duration-500">
            <div role="status" aria-live="polite" class="atlas-loading-card">
              <div class="atlas-loading-mark" aria-hidden="true"><i></i><i></i><i></i></div>
              <div class="min-w-0 flex-1">
                <p data-loading-label class="text-sm font-semibold tracking-[-0.02em] text-[#14231e]">
                  Drawing the network
                </p>
                <p data-loading-detail class="mt-1 text-[11px] font-medium text-[#718078]">
                  Preparing the map
                </p>
                <div
                  data-loading-progress
                  role="progressbar"
                  aria-label="Transit data loading progress"
                  aria-valuemin="0"
                  aria-valuemax="100"
                  class="map-loading__progress mt-3"
                >
                  <span data-loading-bar class="map-loading__bar map-loading__bar--indeterminate">
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <header class="atlas-topbar pointer-events-none absolute inset-x-0 top-0 z-30 flex items-start justify-between p-3 sm:p-5">
          <button
            :if={!@sidebar_open?}
            id="show-map-sidebar"
            type="button"
            phx-click="toggle-sidebar"
            aria-label="Show map menu"
            class="atlas-brand pointer-events-auto"
          >
            <span class="atlas-wordmark" aria-hidden="true"><i></i><i></i><i></i></span>
            <span><strong>WAYLINE</strong><small>{region_label(@region)}</small></span>
          </button>

          <div id="map-control-stack" class="pointer-events-auto ml-auto flex items-center gap-2">
            <div class="atlas-zoom hidden items-center md:flex">
              <button
                id="map-zoom-out"
                type="button"
                phx-click={JS.dispatch("map:zoom-out", to: "#transit-map")}
                aria-label="Zoom out"
              >
                <.icon name="hero-minus" class="size-4" />
              </button>
              <span id="map-zoom-readout" aria-hidden="true">5.5</span>
              <button
                id="map-zoom-in"
                type="button"
                phx-click={JS.dispatch("map:zoom-in", to: "#transit-map")}
                aria-label="Zoom in"
              >
                <.icon name="hero-plus" class="size-4" />
              </button>
            </div>
            <button
              id="map-locate"
              type="button"
              phx-click={JS.dispatch("map:locate", to: "#transit-map")}
              aria-label="Go to my location"
              class="atlas-round-button"
            >
              <.icon name="hero-paper-airplane-solid" class="size-4 -rotate-45" />
            </button>
            <button
              id="map-options-button"
              type="button"
              phx-click="toggle-options"
              aria-label="Map settings"
              aria-expanded={to_string(@options_open?)}
              class={["atlas-round-button", @options_open? && "is-active"]}
            >
              <.icon name="hero-adjustments-horizontal" class="size-[18px]" />
            </button>
          </div>
        </header>

        <aside
          :if={@sidebar_open?}
          id="map-sidebar"
          aria-label="Transit map menu"
          class="atlas-panel absolute z-40 flex min-h-0 flex-col overflow-hidden"
        >
          <header class="shrink-0 px-5 pt-5">
            <div class="flex items-center gap-3">
              <div class="atlas-wordmark" aria-hidden="true"><i></i><i></i><i></i></div>
              <div class="min-w-0 flex-1">
                <p class="text-[10px] font-bold tracking-[0.22em] text-[#76857d]">NETWORK ATLAS</p>
                <h1 class="mt-0.5 text-[22px] font-semibold tracking-[-0.055em] text-[#10221b]">
                  Wayline
                </h1>
              </div>
              <button
                id="hide-map-sidebar"
                type="button"
                phx-click="toggle-sidebar"
                aria-label="Hide map menu"
                class="atlas-close-button"
              >
                <.icon name="hero-chevron-down" class="size-4 sm:hidden" />
                <.icon name="hero-chevron-left" class="hidden size-4 sm:block" />
              </button>
            </div>

            <.form
              for={@search_form}
              id="map-search-form"
              phx-submit="search"
              class="atlas-search mt-5"
            >
              <.icon name="hero-magnifying-glass" class="size-[18px] shrink-0 text-[#728078]" />
              <.input
                field={@search_form[:query]}
                type="search"
                aria-label="Search stations and stops"
                placeholder="Find a station or line"
                autocomplete="off"
                class="min-w-0 flex-1 border-0 bg-transparent p-0 text-[13px] font-medium text-[#15241e] outline-none ring-0 placeholder:text-[#829087] focus:ring-0"
              />
              <button
                :if={@search_form[:query].value not in [nil, ""]}
                id="clear-map-search"
                type="button"
                phx-click="clear-search"
                aria-label="Clear search"
                class="grid size-6 place-items-center rounded-full bg-[#dfe6e1] text-[#526159] transition hover:bg-[#d3ddd6]"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </.form>
            <p
              :if={@search_message}
              id="map-search-message"
              class="mt-2 px-1 text-[11px] font-medium text-[#65736b]"
            >
              {@search_message}
            </p>

            <nav id="map-menu-tabs" aria-label="Map menu sections" class="atlas-tabs mt-4">
              <button
                :for={
                  {panel, label} <- [{"explore", "Explore"}, {"trip", "Plan"}, {"layers", "Lines"}]
                }
                id={"map-menu-#{panel}"}
                type="button"
                phx-click="open-panel"
                phx-value-panel={panel}
                aria-current={if(@active_panel == panel, do: "page", else: "false")}
                class={[@active_panel == panel && "is-active"]}
              >
                {label}
              </button>
            </nav>
          </header>

          <div id="map-menu-content" class="atlas-scroll min-h-0 flex-1 overflow-y-auto px-5 pb-5">
            <section :if={@active_panel == "explore"} id="explore-menu" class="pt-5">
              <div class="atlas-eyebrow">
                <span>Selected network</span><span class="atlas-live"><i></i>Live data</span>
              </div>
              <div class="mt-2.5 space-y-2">
                <button
                  :for={{region, label, description, places} <- regions()}
                  id={"region-#{region}"}
                  type="button"
                  phx-click="region"
                  phx-value-region={region}
                  aria-pressed={to_string(@region == region)}
                  class={["atlas-region", @region == region && "is-active"]}
                >
                  <span class="atlas-region-index">
                    {if(region == "great-britain", do: "01", else: "02")}
                  </span>
                  <span class="min-w-0 flex-1">
                    <strong>{label}</strong><small>{places}</small><em>{description}</em>
                  </span>
                  <.icon :if={@region == region} name="hero-check" class="size-4 shrink-0" />
                </button>
              </div>

              <div class="atlas-stat-grid mt-4">
                <div>
                  <strong>{total_routes(@counts) |> format_count()}</strong><span>routes mapped</span>
                </div>
                <div><strong>{MapSet.size(@enabled)}</strong><span>active modes</span></div>
              </div>

              <button
                id="explore-layers-shortcut"
                type="button"
                phx-click="open-panel"
                phx-value-panel="layers"
                class="atlas-feature-card mt-4"
              >
                <span class="atlas-feature-lines" aria-hidden="true"><i></i><i></i><i></i></span>
                <span class="min-w-0 flex-1">
                  <strong>Shape your view</strong><small>Choose which networks meet on the map.</small>
                </span>
                <.icon name="hero-arrow-up-right" class="size-4" />
              </button>
            </section>

            <section :if={@active_panel == "trip"} id="trip-menu" class="pt-5">
              <div class="atlas-eyebrow"><span>Journey planner</span><span>fewest changes</span></div>
              <.form
                for={@trip_form}
                id="trip-form"
                phx-submit="plan-trip"
                class="atlas-trip-form mt-3"
              >
                <div class="atlas-trip-input">
                  <i class="origin"></i>
                  <.input
                    field={@trip_form[:from]}
                    type="text"
                    aria-label="Start station"
                    placeholder="Starting station"
                    autocomplete="off"
                    class="w-full border-0 bg-transparent p-0 text-[13px] font-medium outline-none ring-0 placeholder:text-[#849087] focus:ring-0"
                  />
                </div>
                <div class="atlas-trip-rail" aria-hidden="true"></div>
                <div class="atlas-trip-input">
                  <i class="destination"></i>
                  <.input
                    field={@trip_form[:to]}
                    type="text"
                    aria-label="Destination station"
                    placeholder="Destination"
                    autocomplete="off"
                    class="w-full border-0 bg-transparent p-0 text-[13px] font-medium outline-none ring-0 placeholder:text-[#849087] focus:ring-0"
                  />
                </div>
                <button id="plan-trip-button" type="submit" class="atlas-primary-button mt-3">
                  Find a route <.icon name="hero-arrow-right" class="size-4" />
                </button>
              </.form>
              <p :if={@journey_error} id="trip-error" class="atlas-alert mt-3">{@journey_error}</p>
              <div :if={@journey} id="trip-itinerary" class="mt-4">
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="text-base font-semibold tracking-[-0.03em]">
                      {@journey.origin.name} → {@journey.destination.name}
                    </p>
                    <p class="mt-1 text-[10px] font-bold tracking-[0.12em] text-[#517064] uppercase">
                      {transfers_label(@journey.transfers)}
                    </p>
                  </div>
                  <button
                    id="clear-trip-button"
                    type="button"
                    phx-click="clear-trip"
                    aria-label="Clear trip"
                    class="atlas-close-button"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
                <ol class="mt-4 space-y-2">
                  <li
                    :for={{leg, index} <- Enum.with_index(@journey.legs)}
                    id={"trip-leg-#{index}"}
                    class="atlas-leg"
                  >
                    <span class="atlas-line-badge" style={"--line-color: #{line_color(leg.line)}"}>
                      {leg.line.name}
                    </span>
                    <p>
                      <strong>{leg.from.name}</strong>
                      <.icon name="hero-arrow-right" class="size-3.5" /><strong>{leg.to.name}</strong>
                    </p>
                  </li>
                </ol>
              </div>
            </section>

            <section :if={@active_panel == "layers"} id="layers-menu" class="pt-5">
              <div class="atlas-eyebrow">
                <span>Visible lines</span><span>{MapSet.size(@enabled)} active</span>
              </div>
              <div class="mt-3 space-y-4">
                <section
                  :for={{group, group_label, _group_icon, modes} <- mode_groups()}
                  class="atlas-layer-group"
                >
                  <header>
                    <h2>{group_label}</h2>
                    <button
                      :if={length(group_categories(group, @counts)) > 1}
                      id={"group-toggle-#{group}"}
                      type="button"
                      phx-click="toggle-group"
                      phx-value-group={group}
                    >
                      {if(group_all_enabled?(group, @counts, @enabled),
                        do: "Hide all",
                        else: "Show all"
                      )}
                    </button>
                  </header>
                  <button
                    :for={{cat, label, description} <- modes}
                    id={"layer-toggle-#{cat}"}
                    type="button"
                    role="switch"
                    aria-checked={to_string(MapSet.member?(@enabled, cat))}
                    phx-click="toggle"
                    phx-value-cat={cat}
                    disabled={route_count(@counts, cat) == 0}
                    class="layer-row"
                  >
                    <span
                      class="atlas-line-swatch"
                      style={"--swatch: #{RouteTypes.default_color(cat)}"}
                    >
                    </span>
                    <span class="min-w-0 flex-1">
                      <strong>{label}</strong><small>{description}</small>
                    </span>
                    <span class="atlas-count">{route_count(@counts, cat) |> format_count()}</span>
                    <span
                      class={["atlas-toggle", MapSet.member?(@enabled, cat) && "is-on"]}
                      aria-hidden="true"
                    >
                      <i></i>
                    </span>
                  </button>
                </section>
              </div>
              <div :if={@counts == %{}} id="empty-feed-notice" class="atlas-alert mt-4">
                No feeds have been imported yet.
              </div>
            </section>
          </div>

          <footer class="atlas-panel-footer">
            <span>{region_label(@region)}</span><span>GTFS · OpenFreeMap</span>
          </footer>
        </aside>

        <section
          :if={@options_open?}
          id="map-options-menu"
          aria-label="Map settings"
          class="atlas-options absolute z-50"
        >
          <div class="atlas-eyebrow px-1"><span>Map display</span><span>Details</span></div>
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
          >
            <.icon name={icon} class="size-4" /><span>{label}</span><span
              class={["atlas-toggle", MapSet.member?(@details, detail) && "is-on"]}
              aria-hidden="true"
            ><i></i></span>
          </button>
          <button
            id="map-live-traffic"
            type="button"
            role="switch"
            aria-checked={to_string(@live_traffic)}
            phx-click="toggle-live-traffic"
          >
            <.icon name="hero-signal" class="size-4" /><span>Moving trains</span><span
              class={["atlas-toggle", @live_traffic && "is-on"]}
              aria-hidden="true"
            ><i></i></span>
          </button>
        </section>

        <div class="atlas-map-key pointer-events-none absolute z-20 hidden sm:flex">
          <span><i class="bg-[#e32017]"></i>Metro</span><span><i class="bg-[#1d4ed8]"></i>Rail</span><span><i class="bg-[#00a65f]"></i>Tram</span><span>Drag to explore</span>
        </div>
      </main>
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
