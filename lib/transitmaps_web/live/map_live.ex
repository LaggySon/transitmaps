defmodule TransitmapsWeb.MapLive do
  use TransitmapsWeb, :live_view

  alias Transitmaps.Agencies
  alias Transitmaps.Catalog
  alias Transitmaps.Gtfs.RouteTypes
  alias Transitmaps.Packages
  alias Transitmaps.Search
  alias Transitmaps.Stations

  @mode_groups [
    {"rail", "Rail",
     [
       {"metro", "Metro", "Underground and subway"},
       {"tram", "Tram", "Light rail and streetcar"},
       {"rail", "National Rail", "Regional and commuter rail"},
       {"intercity", "Intercity", "Long-distance and high-speed"}
     ]},
    {"road", "Road",
     [
       {"bus", "Bus", "Local bus services"},
       {"coach", "Coach", "Intercity road services"}
     ]},
    {"water", "Water",
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
    {"food", "Food & drink", "#C2571A"},
    {"shopping", "Shopping", "#9C4A93"},
    {"culture", "Culture", "#2F6F9F"},
    {"outdoors", "Outdoors", "#3F7D4E"},
    {"essentials", "Essentials", "#6B6B72"}
  ]

  @default_enabled ~w(metro tram rail intercity ferry)
  @default_details ~w(labels stops)
  @details ~w(labels stops)
  @place_ids for {id, _label, _color} <- @place_groups, do: id
  @mode_ids for {_group, _label, modes} <- @mode_groups,
                {id, _label, _description} <- modes,
                do: id
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
    packages = Agencies.packages()

    package_imports =
      if visual_test?,
        do: %{},
        else: Agencies.imports(Enum.flat_map(packages, & &1.catalog_ids))

    {:ok,
     socket
     |> assign(:page_title, "Transit Maps")
     |> assign(:visual_test?, visual_test?)
     |> assign(:menu_open?, false)
     |> assign(:enabled, list_param(params["modes"], @mode_ids, @default_enabled))
     |> assign(:details, list_param(params["details"], @details, @default_details))
     |> assign(:places, list_param(params["places"], @place_ids, @place_ids))
     |> assign(:hidden, id_param(params["hide"]))
     |> assign(:agency_form, to_form(%{"query" => ""}, as: :agency))
     |> assign(:results, [])
     |> assign(:packages, packages)
     |> assign(:package_results, [])
     |> assign(:station_results, [])
     |> assign(:packages_open?, false)
     |> assign(:imports, package_imports)
     |> assign(:requested, MapSet.new())
     |> assign(:agency_error, nil)
     # Nothing is in view until the map says what it shows.
     |> assign(:view_known?, false)
     |> assign_feeds(feeds, [])}
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
     |> push_event("details-changed", %{enabled: MapSet.to_list(details)})
     |> push_url_state()}
  end

  # The map reports which agencies overlap what is on screen; the menu's
  # mode counts and agency list follow it.
  def handle_event("view", %{"feeds" => feed_ids}, socket) when is_list(feed_ids) do
    {:noreply,
     socket
     |> assign(:view_known?, true)
     |> assign_feeds(socket.assigns.feeds, feed_ids)}
  end

  def handle_event("search-agencies", %{"agency" => %{"query" => query}}, socket) do
    results = on_map_matches(socket.assigns.feeds, query) ++ Catalog.search(query)
    package_ids = MapSet.new(Packages.search(query), & &1.id)

    {:noreply,
     socket
     |> assign(:agency_form, to_form(%{"query" => query}, as: :agency))
     |> assign(:results, results)
     |> assign(:package_results, Enum.filter(socket.assigns.packages, &(&1.id in package_ids)))
     |> assign(:station_results, Stations.search(query))
     |> update(:imports, &Map.merge(&1, Agencies.imports(Enum.map(results, fn r -> r.id end))))
     |> assign(:agency_error, nil)}
  end

  # A pack lands agency by agency, so the map goes there straight away and
  # draws each one as it arrives.
  def handle_event("add-package", %{"id" => package_id}, socket) do
    case Agencies.request_package(package_id) do
      {:ok, feed_imports} ->
        {:noreply,
         socket
         |> update(:imports, &Map.merge(&1, Map.new(feed_imports, fn i -> {i.catalog_id, i} end)))
         |> assign(:agency_error, nil)
         |> fly_to_package(package_id)}

      {:error, :busy} ->
        {:noreply,
         assign(socket, :agency_error, "The download queue is full. Try again in a few minutes.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :agency_error, "This pack cannot be downloaded.")}
    end
  end

  # The map flies to the station and opens its details once its stops land.
  def handle_event("show-station", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {index, ""} when index >= 0 ->
        case Enum.at(socket.assigns.station_results, index) do
          nil ->
            {:noreply, socket}

          station ->
            {:noreply,
             socket
             |> assign(:menu_open?, false)
             |> push_event("show-station", %{
               lng: station.lon,
               lat: station.lat,
               name: station.name
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle-packages", _params, socket) do
    {:noreply, update(socket, :packages_open?, &(!&1))}
  end

  def handle_event("show-package", %{"id" => package_id}, socket) do
    {:noreply, socket |> assign(:menu_open?, false) |> fly_to_package(package_id)}
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
         assign(socket, :agency_error, "The download queue is full. Try again in a few minutes.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :agency_error, "This agency cannot be downloaded.")}
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
         |> push_event("agencies-hidden", %{hidden: MapSet.to_list(hidden)})
         |> push_url_state()}

      _ ->
        {:noreply, socket}
    end
  end

  # From the empty-view prompt: open the menu with the search focused.
  def handle_event("search-here", _params, socket) do
    {:noreply, socket |> assign(:menu_open?, true) |> push_event("focus-search", %{})}
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
    words = Search.words(query)

    for feed <- feeds,
        is_nil(feed.catalog_id),
        Search.match?(words, Search.index([feed.label])) do
      %{id: "on-map-#{feed.id}", label: feed.label, place: "On the map", feed_id: feed.id}
    end
  end

  # Packs come grouped by region; the menu heads each group once.
  defp packages_by_region(packages) do
    packages
    |> Enum.chunk_by(& &1.region)
    |> Enum.map(&{hd(&1).region, &1})
  end

  defp fly_to_package(socket, package_id) do
    case Enum.find(socket.assigns.packages, &(&1.id == package_id)) do
      nil -> socket
      package -> push_event(socket, "fly-to", %{bounds: package.bounds})
    end
  end

  # How far a pack's download has got: members on the map, on their way, or
  # turned away (an agency without shapes, say).
  defp package_progress(package, feeds, imports) do
    downloaded = MapSet.new(feeds, & &1.catalog_id)

    Enum.reduce(
      package.catalog_ids,
      %{ready: 0, pending: 0, failed: 0, total: length(package.catalog_ids)},
      fn catalog_id, progress ->
        key =
          cond do
            MapSet.member?(downloaded, catalog_id) -> :ready
            match?(%{status: s} when s in ~w(queued importing), imports[catalog_id]) -> :pending
            match?(%{status: "failed"}, imports[catalog_id]) -> :failed
            true -> nil
          end

        if key, do: Map.update!(progress, key, &(&1 + 1)), else: progress
      end
    )
  end

  defp result_feed(%{feed_id: feed_id}, feeds), do: Enum.find(feeds, &(&1.id == feed_id))
  defp result_feed(entry, feeds), do: Enum.find(feeds, &(&1.catalog_id == entry.id))

  # What the map hook needs to decide which agencies are on screen.
  defp map_feeds(feeds), do: Enum.map(feeds, &Map.take(&1, [:id, :bounds]))

  defp put_enabled(socket, enabled) do
    socket
    |> assign(:enabled, enabled)
    |> push_event("categories-changed", %{enabled: MapSet.to_list(enabled)})
    |> push_url_state()
  end

  defp put_places(socket, places) do
    socket
    |> assign(:places, places)
    |> push_event("places-changed", %{enabled: MapSet.to_list(places)})
    |> push_url_state()
  end

  # What the map shows lives in the query string, so a refresh or a shared
  # link keeps it (DESIGN.md section 12.2). Only what differs from the
  # defaults is written, and the map's own view stays in the URL hash.
  defp push_url_state(socket) do
    push_event(socket, "url-state", %{query: url_query(socket.assigns)})
  end

  defp url_query(assigns) do
    lists = [
      {"modes", assigns.enabled, @default_enabled},
      {"details", assigns.details, @default_details},
      {"places", assigns.places, @place_ids}
    ]

    params =
      for {key, set, default} <- lists, set != MapSet.new(default) do
        {key, set |> Enum.sort() |> Enum.join(",")}
      end

    hidden =
      if MapSet.size(assigns.hidden) > 0,
        do: [{"hide", assigns.hidden |> Enum.sort() |> Enum.join(",")}],
        else: []

    Enum.map_join(params ++ hidden, "&", fn {key, value} -> "#{key}=#{value}" end)
  end

  # A comma-separated list from the URL, keeping only the ids it may name.
  # No parameter means the defaults; an empty one means none.
  defp list_param(nil, _allowed, default), do: MapSet.new(default)

  defp list_param(value, allowed, _default) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.filter(&(&1 in allowed)) |> MapSet.new()
  end

  defp list_param(_value, _allowed, default), do: MapSet.new(default)

  defp id_param(value) when is_binary(value) do
    for part <- String.split(value, ",", trim: true),
        {id, ""} <- [Integer.parse(part)],
        into: MapSet.new(),
        do: id
  end

  defp id_param(_value), do: MapSet.new()

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
      {_id, _label, modes} ->
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
      <:aside>
        <span :if={@view_known?} id="view-summary" class="ui-num">
          {agencies_label(length(@visible_feeds))}<span class="ui-sep">·</span>{routes_label(
            total_routes(@counts)
          )} in view
        </span>
      </:aside>

      <h1 class="ui-sr-only">Transit map</h1>

      <div id="transit-explorer" class="tm-explorer">
        <div
          id="transit-map"
          phx-hook="TransitMap"
          phx-update="ignore"
          phx-mounted={
            JS.ignore_attributes(["class", "data-map-*", "data-transit-ready", "data-drawn-lines"])
          }
          data-enabled={Jason.encode!(MapSet.to_list(@enabled))}
          data-details={Jason.encode!(MapSet.to_list(@details))}
          data-places={Jason.encode!(MapSet.to_list(@places))}
          data-place-catalog={Jason.encode!(place_catalog())}
          data-feeds={Jason.encode!(map_feeds(@feeds))}
          data-hidden={Jason.encode!(MapSet.to_list(@hidden))}
          aria-label="Interactive transit map"
          class="tm-map"
        >
          <div class="map-loading tm-loading">
            <div role="status" aria-live="polite" class="ui-panel tm-loading-panel">
              <p data-loading-label class="tm-loading-title">Loading map…</p>
              <p data-loading-detail class="ui-hint">Preparing the basemap</p>
              <div
                data-loading-progress
                role="progressbar"
                aria-label="Transit data loading progress"
                aria-valuemin="0"
                aria-valuemax="100"
                class="ui-progress"
                data-status="progress"
              >
                <div class="ui-progress-fill"></div>
              </div>
            </div>
          </div>
          <section data-map-detail class="tm-detail" aria-label="Details" hidden>
            <button
              type="button"
              data-map-detail-close
              class="ui-button ui-button--ghost ui-button--small tm-detail-close"
              aria-label="Close"
            >
              ✕
            </button>
            <div data-map-detail-body></div>
          </section>
          <div
            data-map-notice
            class="ui-notice tm-map-notice"
            data-status="failure"
            role="alert"
            hidden
          >
            <span data-map-notice-text></span>
            <span class="ui-button-group ui-notice-end">
              <button type="button" data-map-notice-retry class="ui-button ui-button--small">
                Retry
              </button>
              <button
                type="button"
                data-map-notice-dismiss
                class="ui-button ui-button--ghost ui-button--small"
                aria-label="Dismiss"
              >
                ✕
              </button>
            </span>
          </div>
        </div>

        <div
          :if={@view_known? and @visible_feeds == [] and not @menu_open?}
          id="empty-view"
          class="ui-panel tm-empty-view"
          role="status"
        >
          <p>No transit agencies downloaded here yet.</p>
          <button
            id="empty-view-search"
            type="button"
            phx-click="search-here"
            class="ui-button ui-button--small"
          >
            Find one
          </button>
        </div>

        <%!--
          The one menu: everything in it filters what the map shows. It opens
          under its button at the map's top-left corner, and closes on Escape
          or a click anywhere else.
        --%>
        <div
          id="map-menu-root"
          phx-click-away={@menu_open? && "close-menu"}
          phx-window-keydown={@menu_open? && "close-menu"}
          phx-key="Escape"
          class="tm-menu-root"
        >
          <button
            id="map-menu-button"
            type="button"
            phx-click="toggle-menu"
            aria-expanded={to_string(@menu_open?)}
            aria-controls="map-menu"
            class="ui-button ui-button--compact tm-on-map"
          >
            Filters
            <span :if={hidden_count(assigns) > 0} class="tm-menu-count">
              · {hidden_count(assigns)} off
            </span>
          </button>

          <section :if={@menu_open?} id="map-menu" aria-label="Map filters" class="tm-menu">
            <section id="search-menu" class="tm-menu-section" aria-labelledby="search-menu-title">
              <h2 id="search-menu-title" class="ui-panel-title">Search</h2>
              <.form
                for={@agency_form}
                id="agency-search"
                phx-change="search-agencies"
                phx-submit="search-agencies"
              >
                <.input
                  field={@agency_form[:query]}
                  type="search"
                  aria-label="Search stations and agencies"
                  aria-keyshortcuts="/"
                  placeholder="King's Cross, MBTA, Paris"
                  autocomplete="off"
                  autocapitalize="none"
                  spellcheck="false"
                  enterkeyhint="search"
                  phx-debounce="250"
                  class="tm-search"
                />
              </.form>

              <div
                :if={@agency_error}
                id="agency-error"
                class="ui-notice"
                data-status="failure"
                role="alert"
              >
                {@agency_error}
              </div>

              <%= if searching?(@agency_form) do %>
                <h3 :if={@station_results != []} class="ui-label tm-subhead">Stations</h3>
                <ul :if={@station_results != []} id="station-results" class="tm-list">
                  <li
                    :for={{station, index} <- Enum.with_index(@station_results)}
                    id={"station-result-#{index}"}
                    class="tm-row"
                  >
                    <span class="tm-row-text">
                      <span class="ui-row-name ui-clamp" title={station.name}>{station.name}</span>
                      <span class="tm-row-meta ui-truncate">{modes_label(station.categories)}</span>
                    </span>
                    <button
                      type="button"
                      phx-click="show-station"
                      phx-value-index={index}
                      class="ui-button ui-button--quiet ui-button--small tm-row-action"
                    >
                      Show
                    </button>
                  </li>
                </ul>
                <h3 :if={@package_results != []} class="ui-label tm-subhead">Regional packs</h3>
                <ul :if={@package_results != []} id="package-results" class="tm-list">
                  <.package_row
                    :for={package <- @package_results}
                    id={"package-result-#{package.id}"}
                    package={package}
                    progress={package_progress(package, @feeds, @imports)}
                  />
                </ul>
                <h3 :if={@results != []} class="ui-label tm-subhead">Agencies</h3>
                <ul id="agency-results" class="tm-list" aria-live="polite">
                  <li
                    :for={entry <- @results}
                    id={"agency-result-#{dom_key(entry.id)}"}
                    class="tm-row"
                  >
                    <span class="tm-row-text">
                      <span class="ui-row-name ui-clamp" title={entry.label}>{entry.label}</span>
                      <.agency_meta entry={entry} feed_import={@imports[entry.id]} />
                    </span>
                    <.agency_action
                      entry={entry}
                      feed={result_feed(entry, @feeds)}
                      feed_import={@imports[entry.id]}
                    />
                  </li>
                </ul>
                <p
                  :if={@results == [] and @package_results == [] and @station_results == []}
                  id="agency-results-empty"
                  class="ui-empty"
                >
                  Nothing matches “{@agency_form[:query].value}”. Try a station, an operator or a city.
                </p>
              <% end %>
            </section>

            <section
              :if={not searching?(@agency_form)}
              id="agency-menu"
              class="tm-menu-section"
              aria-labelledby="agency-menu-title"
            >
              <h2 id="agency-menu-title" class="ui-panel-title">Agencies</h2>
              <div id="package-menu">
                <button
                  id="packages-toggle"
                  type="button"
                  phx-click="toggle-packages"
                  aria-expanded={to_string(@packages_open?)}
                  aria-controls="packages"
                  class="tm-disclosure"
                >
                  Regional packs <span class="ui-panel-title-aside">{length(@packages)} regions</span>
                </button>
                <div :if={@packages_open?} id="packages">
                  <p class="ui-hint">Every agency of a region in one go.</p>
                  <div
                    :for={{region, packages} <- packages_by_region(@packages)}
                    id={"packages-#{dom_key(region)}"}
                  >
                    <h3 class="ui-label tm-region">{region}</h3>
                    <ul class="tm-list">
                      <.package_row
                        :for={package <- packages}
                        id={"package-#{package.id}"}
                        package={package}
                        progress={package_progress(package, @feeds, @imports)}
                      />
                    </ul>
                  </div>
                </div>
              </div>

              <h3 class="ui-label tm-subhead">
                In view <span class="ui-panel-title-aside ui-num">{length(@visible_feeds)}</span>
              </h3>
              <ul :if={@visible_feeds != []} id="agencies-in-view" class="tm-list">
                <li :for={feed <- @visible_feeds}>
                  <.toggle
                    id={"agency-toggle-#{feed.id}"}
                    on={not MapSet.member?(@hidden, feed.id)}
                    phx-click="toggle-agency"
                    phx-value-id={feed.id}
                    label={feed.label}
                  />
                </li>
              </ul>
              <p :if={@visible_feeds == [] and @view_known?} id="agencies-in-view" class="ui-empty">
                No agencies downloaded here yet. Search to add one.
              </p>
              <p :if={not @view_known?} id="agencies-in-view" class="ui-loading" role="status">
                Loading the agencies in view…
              </p>
            </section>

            <section
              :for={{group, group_label, modes} <- mode_groups()}
              id={"layers-#{group}"}
              class="tm-menu-section"
              aria-labelledby={"layers-#{group}-title"}
            >
              <h2 id={"layers-#{group}-title"} class="ui-panel-title">
                {group_label}
                <button
                  :if={length(group_categories(group, @counts)) > 1}
                  id={"group-toggle-#{group}"}
                  type="button"
                  phx-click="toggle-group"
                  phx-value-group={group}
                  class="ui-button ui-button--ghost ui-button--small"
                >
                  {if group_all_enabled?(group, @counts, @enabled), do: "Hide all", else: "Show all"}
                </button>
              </h2>
              <ul class="tm-list">
                <li :for={{cat, label, _description} <- modes}>
                  <.toggle
                    id={"layer-toggle-#{cat}"}
                    on={MapSet.member?(@enabled, cat)}
                    phx-click="toggle"
                    phx-value-cat={cat}
                    disabled={route_count(@counts, cat) == 0}
                    title={route_count(@counts, cat) == 0 && "No #{label} routes in view"}
                    label={label}
                    swatch={RouteTypes.default_color(cat)}
                    count={route_count(@counts, cat)}
                  />
                </li>
              </ul>
            </section>

            <section id="details-menu" class="tm-menu-section" aria-labelledby="details-menu-title">
              <h2 id="details-menu-title" class="ui-panel-title">Map details</h2>
              <ul class="tm-list">
                <li :for={{detail, label} <- [{"labels", "Station names"}, {"stops", "Stop markers"}]}>
                  <.toggle
                    id={"map-detail-#{detail}"}
                    on={MapSet.member?(@details, detail)}
                    phx-click="toggle-detail"
                    phx-value-detail={detail}
                    label={label}
                  />
                </li>
              </ul>
            </section>

            <section id="places-menu" class="tm-menu-section" aria-labelledby="places-menu-title">
              <h2 id="places-menu-title" class="ui-panel-title">
                Places
                <button
                  id="group-toggle-places"
                  type="button"
                  phx-click="toggle-place-group"
                  class="ui-button ui-button--ghost ui-button--small"
                >
                  {if all_places_enabled?(@places), do: "Hide all", else: "Show all"}
                </button>
              </h2>
              <ul class="tm-list">
                <li :for={{place, label, color} <- place_groups()}>
                  <.toggle
                    id={"place-toggle-#{place}"}
                    on={MapSet.member?(@places, place)}
                    phx-click="toggle-place"
                    phx-value-place={place}
                    label={label}
                    swatch={color}
                    mark="dot"
                  />
                </li>
              </ul>
              <p class="ui-hint">Places appear from zoom 14 · © OpenStreetMap</p>
            </section>

            <div :if={@feeds == []} id="empty-feed-notice" class="tm-menu-section">
              <div class="ui-notice" data-status="progress" role="status">
                No agencies downloaded yet. Search for one to start drawing routes.
              </div>
            </div>
          </section>
        </div>

        <div id="map-control-stack" class="tm-controls">
          <div class="tm-control-group" role="group" aria-label="Zoom">
            <button
              id="map-zoom-in"
              type="button"
              phx-click={JS.dispatch("map:zoom-in", to: "#transit-map")}
              aria-label="Zoom in"
              class="ui-button tm-on-map tm-map-button"
            >
              +
            </button>
            <button
              id="map-zoom-out"
              type="button"
              phx-click={JS.dispatch("map:zoom-out", to: "#transit-map")}
              aria-label="Zoom out"
              class="ui-button tm-on-map tm-map-button"
            >
              −
            </button>
          </div>

          <button
            id="map-locate"
            type="button"
            phx-click={JS.dispatch("map:locate", to: "#transit-map")}
            aria-label="Go to my location"
            title="Go to my location"
            class="ui-button tm-on-map tm-map-button"
          >
            <svg
              viewBox="0 0 12 12"
              fill="none"
              stroke="currentColor"
              stroke-width="1.3"
              aria-hidden="true"
              focusable="false"
            >
              <circle cx="6" cy="6" r="3.2" />
              <path d="M6 0.5v2.3M6 9.2v2.3M0.5 6h2.3M9.2 6h2.3" />
            </svg>
          </button>
        </div>

        <div
          id="map-zoom-readout"
          phx-update="ignore"
          class="tm-zoom-readout"
          data-shown={zoom_readout?()}
          aria-hidden="true"
        >
          z5.5
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp agencies_label(1), do: "1 agency"
  defp agencies_label(count), do: "#{format_count(count)} agencies"

  defp routes_label(1), do: "1 route"
  defp routes_label(count), do: "#{format_count(count)} routes"

  # "Metro · National Rail", in the menu's words for each mode.
  defp modes_label(categories) do
    labels =
      for {_group, _label, modes} <- @mode_groups,
          {cat, label, _} <- modes,
          into: %{},
          do: {cat, label}

    Enum.map_join(categories, " · ", &Map.get(labels, &1, &1))
  end

  defp searching?(form), do: form[:query].value not in [nil, ""]

  # How many of the things the menu switches are off right now, so a closed
  # menu still says the map isn't showing everything.
  defp hidden_count(assigns) do
    modes_off =
      Enum.count(@mode_ids, fn cat ->
        Map.get(assigns.counts, cat, 0) > 0 and not MapSet.member?(assigns.enabled, cat)
      end)

    agencies_off = Enum.count(assigns.visible_feeds, &MapSet.member?(assigns.hidden, &1.id))

    modes_off + agencies_off
  end

  # Catalog ids are free text; DOM ids keep only the safe characters.
  defp dom_key(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")

  # The one place a download's state becomes a word and a state role
  # (DESIGN.md section 3.1).
  defp import_state(%{status: "queued"}), do: {"Waiting", "neutral"}
  defp import_state(%{status: "importing"}), do: {"Downloading", "progress"}
  defp import_state(%{status: "failed"}), do: {"Failed", "failure"}
  defp import_state(_feed_import), do: nil

  defp in_flight?(feed_import),
    do: match?(%{status: s} when s in ~w(queued importing), feed_import)

  attr :id, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true
  attr :swatch, :string, default: nil, doc: "a colour from the data, shown as a legend mark"
  attr :mark, :string, values: ~w(line dot), default: "line"
  attr :count, :integer, default: nil
  attr :rest, :global, include: ~w(disabled title)

  # A row that switches one thing on the map, drawn as a checkbox.
  defp toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="checkbox"
      aria-checked={to_string(@on)}
      class="tm-toggle"
      {@rest}
    >
      <span class="tm-check" aria-hidden="true"></span>
      <span
        :if={@swatch}
        class={"tm-swatch-#{@mark}"}
        style={"--swatch: #{@swatch}"}
        aria-hidden="true"
      >
      </span>
      <span class="tm-toggle-label ui-truncate">{@label}</span>
      <span :if={@count} class="tm-toggle-count ui-mono">{format_count(@count)}</span>
    </button>
    """
  end

  attr :entry, :map, required: true
  attr :feed_import, :any, default: nil

  # Where a result serves, or why its last download failed.
  defp agency_meta(assigns) do
    ~H"""
    <%= if match?(%{status: "failed"}, @feed_import) do %>
      <span class="tm-row-meta ui-hint--error ui-truncate" title={@feed_import.error}>
        Download failed{if @feed_import.error, do: ": #{@feed_import.error}", else: "."}
      </span>
    <% else %>
      <span class="tm-row-meta ui-truncate" title={@entry.place}>{@entry.place}</span>
    <% end %>
    """
  end

  attr :entry, :map, required: true
  attr :feed, :map, default: nil
  attr :feed_import, :any, default: nil

  # The one thing a search result offers: show it, wait for it, or get it.
  defp agency_action(assigns) do
    ~H"""
    <%= cond do %>
      <% in_flight?(@feed_import) -> %>
        <.import_badge feed_import={@feed_import} />
      <% @feed -> %>
        <button
          type="button"
          phx-click="show-agency"
          phx-value-id={@feed.id}
          class="ui-button ui-button--quiet ui-button--small tm-row-action"
        >
          Show
        </button>
      <% match?(%{status: "failed"}, @feed_import) -> %>
        <button
          type="button"
          phx-click="add-agency"
          phx-value-id={@entry.id}
          phx-disable-with="Retrying…"
          class="ui-button ui-button--small tm-row-action"
        >
          Retry
        </button>
      <% true -> %>
        <button
          type="button"
          phx-click="add-agency"
          phx-value-id={@entry.id}
          phx-disable-with="Adding…"
          class="ui-button ui-button--small tm-row-action"
        >
          + Add
        </button>
    <% end %>
    """
  end

  attr :feed_import, :map, required: true

  defp import_badge(assigns) do
    {word, role} = import_state(assigns.feed_import)
    assigns = assign(assigns, word: word, role: role)

    ~H"""
    <span class="ui-badge tm-row-action" data-status={@role}>
      <span :if={@role == "progress"} class="ui-dot"></span>{@word}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :package, :map, required: true
  attr :progress, :map, required: true

  defp package_row(assigns) do
    ~H"""
    <li id={@id} class="tm-row">
      <span class="tm-row-text">
        <span class="ui-row-name ui-clamp" title={@package.label}>{@package.label}</span>
        <span class="tm-row-meta ui-truncate" title={@package.place}>
          {agencies_label(@progress.total)}<span class="ui-sep">·</span>{@package.place}
        </span>
      </span>
      <.package_action package={@package} progress={@progress} />
    </li>
    """
  end

  attr :package, :map, required: true
  attr :progress, :map, required: true

  # Like a single agency's action, with a running count while it downloads.
  # A pack is done once every member has landed or been turned away.
  defp package_action(assigns) do
    ~H"""
    <%= cond do %>
      <% @progress.pending > 0 -> %>
        <div
          class="ui-progress ui-progress--labeled tm-pack-progress tm-row-action"
          data-status="progress"
          style={"--value: #{percent(@progress.ready, @progress.total)}%"}
          role="progressbar"
          aria-valuenow={percent(@progress.ready, @progress.total)}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-label={"Downloading: #{@progress.ready} of #{@progress.total} agencies"}
        >
          <div class="ui-progress-fill"></div>
          <span class="ui-progress-label">{@progress.ready}/{@progress.total}</span>
          <span class="ui-progress-label ui-progress-label--on-fill" aria-hidden="true">
            {@progress.ready}/{@progress.total}
          </span>
        </div>
      <% @progress.ready > 0 and @progress.ready + @progress.failed == @progress.total -> %>
        <button
          type="button"
          phx-click="show-package"
          phx-value-id={@package.id}
          class="ui-button ui-button--quiet ui-button--small tm-row-action"
        >
          Show
        </button>
      <% true -> %>
        <button
          type="button"
          phx-click="add-package"
          phx-value-id={@package.id}
          phx-disable-with="Adding…"
          class="ui-button ui-button--small tm-row-action"
        >
          {if @progress.ready > 0, do: "+ Add rest", else: "+ Add"}
        </button>
    <% end %>
    """
  end

  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part * 100 / total)

  defp route_count(counts, cat), do: Map.get(counts, cat, 0)
  defp total_routes(counts), do: counts |> Map.values() |> Enum.sum()

  # Thousands are grouped from 10,000 up (DESIGN.md section 11).
  defp format_count(count) when count >= 10_000 do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_count(count), do: Integer.to_string(count)
end
