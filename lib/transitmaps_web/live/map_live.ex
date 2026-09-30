defmodule TransitmapsWeb.MapLive do
  use TransitmapsWeb, :live_view

  alias Transitmaps.Agencies
  alias Transitmaps.Catalog
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

  # Points of interest come from the basemap's own `poi` vector layer, so a
  # group only needs an identity here: the sidebar renders the label and swatch
  # and the map hook paints a matching pin. Which OSM classes belong to a group
  # is a rendering concern and lives in `assets/js/map_places.js`.
  #
  # The colours are deliberately deeper and greyer than the transit palette in
  # `RouteTypes.default_color/1` — places should read as basemap detail and
  # never compete with a line colour.
  @place_groups [
    {"food", "Food & Drink", "#C2571A"},
    {"shopping", "Shopping", "#9C4A93"},
    {"culture", "Culture", "#2F6F9F"},
    {"outdoors", "Outdoors", "#3F7D4E"},
    {"essentials", "Essentials", "#6B6B72"}
  ]

  @default_enabled ~w(metro tram rail intercity ferry)
  @default_details ~w(labels stops)
  @details ~w(labels stops)
  @place_ids for {id, _label, _color} <- @place_groups, do: id
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

  # The visual suite mocks the GeoJSON API, so it draws one stand-in agency
  # covering the opening view instead of whatever the dev database holds.
  @visual_feeds [
    %{
      id: 1,
      label: "Fixture Rail",
      catalog_id: nil,
      bounds: [[-8.8, 49.7], [2.1, 59.2]],
      counts: @visual_counts
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    visual_test? = params["visual_test"] == "1" and @visual_testing

    if connected?(socket) and not visual_test?, do: Agencies.subscribe()

    feeds = if visual_test?, do: @visual_feeds, else: Agencies.list_feeds()

    {:ok,
     socket
     |> assign(:page_title, "Transit Maps")
     |> assign(:visual_test?, visual_test?)
     |> assign(:menu_open?, false)
     |> assign(:enabled, MapSet.new(@default_enabled))
     |> assign(:details, MapSet.new(@default_details))
     |> assign(:places, MapSet.new(@place_ids))
     |> assign(:hidden, MapSet.new())
     |> assign(:agency_form, to_form(%{"query" => ""}, as: :agency))
     |> assign(:results, [])
     |> assign(:imports, %{})
     |> assign(:requested, MapSet.new())
     |> assign(:agency_error, nil)
     |> assign_feeds(feeds, Enum.map(feeds, & &1.id))}
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

  def handle_event("toggle-place", %{"place" => place}, socket) when place in @place_ids do
    {:noreply, put_places(socket, toggle_member(socket.assigns.places, place))}
  end

  def handle_event("toggle-place-group", _params, socket) do
    places = socket.assigns.places

    places = if all_places_enabled?(places), do: MapSet.new(), else: MapSet.new(@place_ids)

    {:noreply, put_places(socket, places)}
  end

  def handle_event("toggle-detail", %{"detail" => detail}, socket) when detail in @details do
    details = toggle_member(socket.assigns.details, detail)

    {:noreply,
     socket
     |> assign(:details, details)
     |> push_event("details-changed", %{enabled: MapSet.to_list(details)})}
  end

  # The map reports which agencies overlap what is on screen; the menu's
  # mode counts and agency list follow it.
  def handle_event("view", %{"feeds" => feed_ids}, socket) when is_list(feed_ids) do
    {:noreply, assign_feeds(socket, socket.assigns.feeds, feed_ids)}
  end

  def handle_event("search-agencies", %{"agency" => %{"query" => query}}, socket) do
    results = on_map_matches(socket.assigns.feeds, query) ++ Catalog.search(query)

    {:noreply,
     socket
     |> assign(:agency_form, to_form(%{"query" => query}, as: :agency))
     |> assign(:results, results)
     |> assign(:imports, Agencies.imports(Enum.map(results, & &1.id)))
     |> assign(:agency_error, nil)}
  end

  def handle_event("add-agency", %{"id" => catalog_id}, socket) do
    case Agencies.request(catalog_id) do
      {:ok, feed_import} ->
        {:noreply,
         socket
         |> update(:imports, &Map.put(&1, catalog_id, feed_import))
         |> update(:requested, &MapSet.put(&1, catalog_id))
         |> assign(:agency_error, nil)}

      {:error, :busy} ->
        {:noreply,
         assign(socket, :agency_error, "Lots of agencies are downloading. Try again shortly.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :agency_error, "That agency isn't available to download.")}
    end
  end

  def handle_event("show-agency", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.feeds, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      feed ->
        {:noreply,
         socket
         |> assign(:menu_open?, false)
         |> push_event("fly-to", %{bounds: feed.bounds})}
    end
  end

  # Hiding is this visitor's own choice; the agency stays downloaded.
  def handle_event("toggle-agency", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {feed_id, ""} ->
        hidden = toggle_member(socket.assigns.hidden, feed_id)

        {:noreply,
         socket
         |> assign(:hidden, hidden)
         |> push_event("agencies-hidden", %{hidden: MapSet.to_list(hidden)})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle-menu", _params, socket) do
    {:noreply, update(socket, :menu_open?, &(!&1))}
  end

  def handle_event("close-menu", _params, socket) do
    {:noreply, assign(socket, :menu_open?, false)}
  end

  @impl true
  def handle_info({:import_updated, feed_import}, socket) do
    {:noreply, update(socket, :imports, &Map.put(&1, feed_import.catalog_id, feed_import))}
  end

  # An agency finished downloading (or was replaced). Every map picks up the
  # new index; the visitor who asked for it is flown there.
  def handle_info(:feeds_changed, socket) do
    feeds = Agencies.list_feeds()
    arrived = Enum.filter(feeds, &MapSet.member?(socket.assigns.requested, &1.catalog_id))

    socket =
      socket
      |> assign_feeds(feeds, socket.assigns.in_view)
      |> push_event("feeds-changed", %{feeds: map_feeds(feeds)})
      |> update(:requested, fn requested ->
        Enum.reduce(arrived, requested, &MapSet.delete(&2, &1.catalog_id))
      end)

    socket =
      case arrived do
        [feed | _] -> push_event(socket, "fly-to", %{bounds: feed.bounds})
        [] -> socket
      end

    {:noreply, socket}
  end

  defp assign_feeds(socket, feeds, in_view_ids) do
    known = MapSet.new(feeds, & &1.id)
    in_view = Enum.filter(in_view_ids, &MapSet.member?(known, &1))
    in_view_set = MapSet.new(in_view)
    visible = Enum.filter(feeds, &MapSet.member?(in_view_set, &1.id))

    counts =
      Enum.reduce(visible, %{}, fn feed, counts ->
        Map.merge(counts, feed.counts, fn _category, a, b -> a + b end)
      end)

    assign(socket,
      feeds: feeds,
      in_view: in_view,
      visible_feeds: visible,
      counts: counts
    )
  end

  # Hand-curated agencies aren't in the catalog, so search finds them among
  # what is already on the map, shaped like catalog results.
  defp on_map_matches(feeds, query) do
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    for feed <- feeds,
        is_nil(feed.catalog_id),
        words != [],
        Enum.all?(words, &String.contains?(String.downcase(feed.label), &1)) do
      %{id: "on-map-#{feed.id}", label: feed.label, place: "On the map", feed_id: feed.id}
    end
  end

  defp result_feed(%{feed_id: feed_id}, feeds), do: Enum.find(feeds, &(&1.id == feed_id))
  defp result_feed(entry, feeds), do: Enum.find(feeds, &(&1.catalog_id == entry.id))

  # What the map hook needs to decide which agencies are on screen.
  defp map_feeds(feeds), do: Enum.map(feeds, &Map.take(&1, [:id, :bounds]))

  defp put_enabled(socket, enabled) do
    socket
    |> assign(:enabled, enabled)
    |> push_event("categories-changed", %{enabled: MapSet.to_list(enabled)})
  end

  defp put_places(socket, places) do
    socket
    |> assign(:places, places)
    |> push_event("places-changed", %{enabled: MapSet.to_list(places)})
  end

  defp toggle_member(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  defp mode_groups, do: @mode_groups
  defp place_groups, do: @place_groups

  defp all_places_enabled?(places), do: Enum.all?(@place_ids, &MapSet.member?(places, &1))

  # The live zoom readout is a debugging aid, so it stays out of production but
  # is always on while developing; the visual suite forces it on via a body
  # class so approved screenshots record the zoom they were taken at.
  defp zoom_readout?, do: @visual_testing

  # The hook paints each pin in its group's colour, so the catalogue travels to
  # the client rather than the palette being restated in JavaScript.
  defp place_catalog do
    for {id, label, color} <- @place_groups, do: %{id: id, label: label, color: color}
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
          data-feeds={Jason.encode!(map_feeds(@feeds))}
          data-hidden={Jason.encode!(MapSet.to_list(@hidden))}
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

        <%!-- The one menu: everything in it filters what the map shows. --%>
        <div
          id="map-menu-root"
          phx-click-away={@menu_open? && "close-menu"}
          phx-window-keydown={@menu_open? && "close-menu"}
          phx-key="Escape"
          class="absolute top-4 left-4 z-40 flex w-[min(17rem,calc(100vw-5.5rem))] flex-col items-start gap-2 sm:top-5 sm:left-5"
        >
          <button
            id="map-menu-button"
            type="button"
            phx-click="toggle-menu"
            aria-expanded={to_string(@menu_open?)}
            aria-controls="map-menu"
            class="map-fab flex h-11 max-w-full items-center gap-2.5 pr-3 pl-2"
          >
            <span class="transit-mark transit-mark--small" aria-hidden="true">
              <span></span><span></span><span></span>
            </span>
            <span class="min-w-0 text-left">
              <span class="block truncate text-[12px] font-bold tracking-[-0.01em] text-[#1d1d1f]">
                Transit Maps
              </span>
              <span class="block truncate text-[10px] font-medium text-[#8a8a8e]">
                {agencies_label(length(@visible_feeds))} · {total_routes(@counts) |> format_count()} routes
              </span>
            </span>
            <.icon
              name="hero-adjustments-horizontal"
              class={[
                "ml-1 size-[18px] shrink-0 transition-colors",
                if(@menu_open?, do: "text-[#007aff]", else: "text-[#8a8a8e]")
              ]}
            />
          </button>

          <section
            :if={@menu_open?}
            id="map-menu"
            aria-label="Map filters"
            class="map-popover flex max-h-[calc(100dvh-6.5rem)] w-full flex-col overflow-hidden"
          >
            <div class="apple-scrollbar min-h-0 flex-1 overflow-y-auto p-1.5">
              <div id="agency-menu" class="px-1 pb-1">
                <.menu_heading label="Agencies" />
                <.form
                  for={@agency_form}
                  id="agency-search"
                  phx-change="search-agencies"
                  phx-submit="search-agencies"
                  class="px-1.5"
                >
                  <.input
                    field={@agency_form[:query]}
                    type="search"
                    aria-label="Find an agency"
                    placeholder="Find an agency — MBTA, Amtrak…"
                    autocomplete="off"
                    phx-debounce="250"
                    class="agency-search"
                  />
                </.form>

                <p
                  :if={@agency_error}
                  id="agency-error"
                  class="px-2.5 pb-1 text-[11px] font-semibold text-[#b3261e]"
                >
                  {@agency_error}
                </p>

                <%= if @agency_form[:query].value not in [nil, ""] do %>
                  <ul id="agency-results">
                    <li
                      :for={entry <- @results}
                      id={"agency-result-#{dom_key(entry.id)}"}
                      class="flex items-center gap-2 rounded-lg px-2.5 py-1.5"
                    >
                      <span class="min-w-0 flex-1">
                        <span class="block truncate text-[12px] font-medium text-[#2c2c2e]">
                          {entry.label}
                        </span>
                        <span class="block truncate text-[10px] font-medium text-[#a4a4a8]">
                          {entry.place}
                        </span>
                      </span>
                      <.agency_action
                        entry={entry}
                        feed={result_feed(entry, @feeds)}
                        feed_import={@imports[entry.id]}
                      />
                    </li>
                    <li
                      :if={@results == []}
                      class="px-2.5 py-2 text-[11px] font-medium text-[#8a8a8e]"
                    >
                      No agencies match.
                    </li>
                  </ul>
                <% else %>
                  <ul id="agencies-in-view">
                    <li :for={feed <- @visible_feeds}>
                      <button
                        id={"agency-toggle-#{feed.id}"}
                        type="button"
                        role="switch"
                        aria-checked={to_string(not MapSet.member?(@hidden, feed.id))}
                        phx-click="toggle-agency"
                        phx-value-id={feed.id}
                        class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition hover:bg-black/[0.035]"
                      >
                        <span class="flex-1 truncate text-[12px] font-medium text-[#2c2c2e]">
                          {feed.label}
                        </span>
                        <.switch on={not MapSet.member?(@hidden, feed.id)} />
                      </button>
                    </li>
                    <li
                      :if={@visible_feeds == []}
                      class="px-2.5 py-2 text-[11px] font-medium text-[#8a8a8e]"
                    >
                      No agencies downloaded here yet. Search to add one.
                    </li>
                  </ul>
                <% end %>
              </div>

              <div :for={{group, group_label, _icon, modes} <- mode_groups()} id={"layers-#{group}"}>
                <div class="my-1.5 h-px bg-black/[0.06]"></div>

                <div class="flex h-6 items-center gap-2 px-2.5">
                  <h3 class="flex-1 text-[9px] font-bold tracking-[0.06em] text-[#9a9a9f] uppercase">
                    {group_label}
                  </h3>
                  <button
                    :if={length(group_categories(group, @counts)) > 1}
                    id={"group-toggle-#{group}"}
                    type="button"
                    phx-click="toggle-group"
                    phx-value-group={group}
                    class="rounded-md px-1.5 py-0.5 text-[10px] font-semibold text-[#007aff] transition hover:bg-[#007aff]/[0.08] active:scale-95"
                  >
                    {if group_all_enabled?(group, @counts, @enabled), do: "Hide all", else: "Show all"}
                  </button>
                </div>

                <button
                  :for={{cat, label, _description} <- modes}
                  id={"layer-toggle-#{cat}"}
                  type="button"
                  role="switch"
                  aria-checked={to_string(MapSet.member?(@enabled, cat))}
                  phx-click="toggle"
                  phx-value-cat={cat}
                  disabled={route_count(@counts, cat) == 0}
                  class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition hover:bg-black/[0.035] disabled:cursor-not-allowed disabled:opacity-35"
                >
                  <span
                    class="size-2.5 shrink-0 rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]"
                    style={"background: #{RouteTypes.default_color(cat)}"}
                  >
                  </span>
                  <span class="flex-1 truncate text-[12px] font-medium text-[#2c2c2e]">{label}</span>
                  <span class="shrink-0 text-[10px] font-medium tabular-nums text-[#a4a4a8]">
                    {route_count(@counts, cat) |> format_count()}
                  </span>
                  <.switch on={MapSet.member?(@enabled, cat)} />
                </button>
              </div>

              <div id="details-menu">
                <div class="my-1.5 h-px bg-black/[0.06]"></div>
                <.menu_heading label="Map details" />
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
                  class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition hover:bg-black/[0.035]"
                >
                  <.icon name={icon} class="size-4 shrink-0 text-[#8a8a8e]" />
                  <span class="flex-1 text-[12px] font-medium text-[#2c2c2e]">{label}</span>
                  <.switch on={MapSet.member?(@details, detail)} />
                </button>
              </div>

              <div id="places-menu">
                <div class="my-1.5 h-px bg-black/[0.06]"></div>

                <div class="flex h-6 items-center gap-2 px-2.5">
                  <h3 class="flex-1 text-[9px] font-bold tracking-[0.06em] text-[#9a9a9f] uppercase">
                    Places
                  </h3>
                  <button
                    id="group-toggle-places"
                    type="button"
                    phx-click="toggle-place-group"
                    class="rounded-md px-1.5 py-0.5 text-[10px] font-semibold text-[#007aff] transition hover:bg-[#007aff]/[0.08] active:scale-95"
                  >
                    {if all_places_enabled?(@places), do: "Hide all", else: "Show all"}
                  </button>
                </div>

                <button
                  :for={{place, label, color} <- place_groups()}
                  id={"place-toggle-#{place}"}
                  type="button"
                  role="switch"
                  aria-checked={to_string(MapSet.member?(@places, place))}
                  phx-click="toggle-place"
                  phx-value-place={place}
                  class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition hover:bg-black/[0.035]"
                >
                  <span
                    class="size-2.5 shrink-0 rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]"
                    style={"background: #{color}"}
                  >
                  </span>
                  <span class="flex-1 truncate text-[12px] font-medium text-[#2c2c2e]">{label}</span>
                  <.switch on={MapSet.member?(@places, place)} />
                </button>

                <p class="px-2.5 pt-1 pb-0.5 text-[9px] font-medium text-[#a4a4a8]">
                  Places appear from zoom 14 · © OpenStreetMap
                </p>
              </div>

              <div
                :if={@counts == %{}}
                id="empty-feed-notice"
                class="mt-1.5 rounded-lg bg-[#fff7df] p-2.5"
              >
                <p class="text-[11px] font-semibold leading-4 text-[#6f5813]">
                  No feeds have been imported yet. Add a GTFS feed to start drawing routes.
                </p>
              </div>
            </div>
          </section>
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

  defp agencies_label(1), do: "1 agency"
  defp agencies_label(count), do: "#{count} agencies"

  # Catalog ids are free text; DOM ids keep only the safe characters.
  defp dom_key(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")

  attr :entry, :map, required: true
  attr :feed, :map, default: nil
  attr :feed_import, :any, default: nil

  # The one thing a search result offers: show it, wait for it, or get it.
  defp agency_action(assigns) do
    ~H"""
    <%= cond do %>
      <% @feed_import && @feed_import.status in ~w(queued importing) -> %>
        <span class="flex shrink-0 items-center gap-1.5 text-[10px] font-semibold text-[#8a8a8e]">
          <span class="map-loading__spinner size-3 rounded-full border-2 border-[#007aff]/20 border-t-[#007aff]">
          </span>
          {if @feed_import.status == "queued", do: "Waiting", else: "Downloading"}
        </span>
      <% @feed -> %>
        <button
          type="button"
          phx-click="show-agency"
          phx-value-id={@feed.id}
          class="agency-action"
        >
          Show
        </button>
      <% true -> %>
        <button
          type="button"
          phx-click="add-agency"
          phx-value-id={@entry.id}
          title={@feed_import && @feed_import.status == "failed" && @feed_import.error}
          class="agency-action agency-action--primary"
        >
          {if @feed_import && @feed_import.status == "failed", do: "Retry", else: "Add"}
        </button>
    <% end %>
    """
  end

  attr :label, :string, required: true

  defp menu_heading(assigns) do
    ~H"""
    <h3 class="flex h-6 items-center px-2.5 text-[9px] font-bold tracking-[0.06em] text-[#9a9a9f] uppercase">
      {@label}
    </h3>
    """
  end

  attr :on, :boolean, required: true

  defp switch(assigns) do
    ~H"""
    <span
      class={[
        "apple-switch relative h-[20px] w-[34px] shrink-0 rounded-full p-0.5 transition-colors duration-200",
        if(@on, do: "bg-[#34c759]", else: "bg-[#d1d1d6]")
      ]}
      aria-hidden="true"
    >
      <span class={[
        "block size-[16px] rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.3)] transition-transform duration-200",
        @on && "translate-x-3.5"
      ]}>
      </span>
    </span>
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
