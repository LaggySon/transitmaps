defmodule TransitmapsWeb.MapLive do
  use TransitmapsWeb, :live_view

  alias Transitmaps.Gtfs
  alias Transitmaps.Gtfs.RouteTypes

  @mode_labels [
    {"metro", "Metro / Subway"},
    {"tram", "Tram / Light Rail"},
    {"rail", "National Rail"},
    {"intercity", "Intercity / High Speed"},
    {"ferry", "Ferry"},
    {"bus", "Bus"},
    {"coach", "Coach"}
  ]

  @default_enabled ~w(metro tram rail intercity ferry)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Transit Map")
     |> assign(:counts, Gtfs.category_counts())
     |> assign(:legend_open?, true)
     |> assign(:enabled, MapSet.new(@default_enabled))}
  end

  @impl true
  def handle_event("toggle", %{"cat" => cat}, socket) when is_binary(cat) do
    enabled = toggle_member(socket.assigns.enabled, cat)

    {:noreply,
     socket
     |> assign(:enabled, enabled)
     |> push_event("categories-changed", %{enabled: MapSet.to_list(enabled)})}
  end

  @impl true
  def handle_event("region", %{"region" => region}, socket)
      when region in ~w(great-britain northeast-corridor) do
    {:noreply, push_event(socket, "map-region", %{region: region})}
  end

  def handle_event("toggle-legend", _params, socket) do
    {:noreply, update(socket, :legend_open?, &(!&1))}
  end

  defp toggle_member(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  defp mode_labels, do: @mode_labels

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative h-screen w-screen overflow-hidden">
      <div
        id="transit-map"
        phx-hook="TransitMap"
        phx-update="ignore"
        data-enabled={Jason.encode!(MapSet.to_list(@enabled))}
        class="!absolute inset-0"
      >
      </div>

      <aside
        :if={@legend_open?}
        id="map-layer-panel"
        class="absolute top-3 left-3 w-[min(19rem,calc(100vw-1.5rem))] overflow-hidden rounded-3xl border border-white/80 bg-white/90 shadow-[0_20px_55px_-20px_rgba(15,23,42,0.35)] backdrop-blur-xl sm:top-5 sm:left-5"
      >
        <header class="border-b border-slate-200/70 px-5 pt-4 pb-3.5">
          <div class="flex items-center gap-3">
            <span class="grid size-9 place-items-center rounded-xl bg-slate-950 text-white shadow-sm">
              <.icon name="hero-map" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h1 class="text-[15px] font-bold tracking-tight text-slate-950">Transit map</h1>
              <p class="mt-0.5 text-[11px] font-medium text-slate-500">
                Great Britain · {total_routes(@counts) |> format_count()} routes
              </p>
            </div>
            <span class="flex items-center gap-1.5 rounded-full bg-emerald-50 px-2 py-1 text-[10px] font-semibold text-emerald-700 ring-1 ring-emerald-600/10">
              <span class="size-1.5 rounded-full bg-emerald-500"></span> Live
            </span>
            <button
              id="hide-map-legend"
              type="button"
              phx-click="toggle-legend"
              aria-label="Hide map legend"
              title="Hide legend"
              class="grid size-8 place-items-center rounded-xl text-slate-500 transition hover:bg-slate-100 hover:text-slate-950 active:scale-95"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </header>

        <div class="space-y-0.5 p-2.5">
          <label
            :for={{cat, label} <- mode_labels()}
            class={[
              "group flex min-h-10 items-center gap-3 rounded-2xl px-2.5 py-2 transition duration-150",
              route_count(@counts, cat) == 0 && "cursor-not-allowed opacity-35",
              route_count(@counts, cat) > 0 &&
                "cursor-pointer hover:bg-slate-100/90 active:scale-[0.99]"
            ]}
          >
            <input
              id={"layer-toggle-#{cat}"}
              type="checkbox"
              class="peer sr-only"
              checked={MapSet.member?(@enabled, cat)}
              disabled={route_count(@counts, cat) == 0}
              phx-click="toggle"
              phx-value-cat={cat}
            />
            <span class="grid size-5 shrink-0 place-items-center rounded-md border border-slate-300 bg-white text-transparent shadow-sm transition peer-checked:border-slate-900 peer-checked:bg-slate-900 peer-checked:text-white">
              <.icon name="hero-check" class="size-3.5" />
            </span>
            <span
              class="size-2.5 shrink-0 rounded-full shadow-[0_0_0_3px_rgba(255,255,255,0.9)]"
              style={"background: #{RouteTypes.default_color(cat)}"}
            >
            </span>
            <span class="min-w-0 flex-1 truncate text-[13px] font-semibold text-slate-700 group-hover:text-slate-950">
              {label}
            </span>
            <span class="rounded-md bg-slate-100 px-1.5 py-0.5 text-[10px] font-semibold tabular-nums text-slate-500 peer-checked:bg-white">
              {route_count(@counts, cat) |> format_count()}
            </span>
          </label>
        </div>

        <p :if={@counts == %{}} class="px-5 pb-4 text-xs text-slate-500">
          No feeds imported yet. Run
          <code class="font-mono">mix gtfs.import &lt;name&gt; &lt;gtfs-zip-url&gt;</code>
        </p>
        <footer class="border-t border-slate-200/70 px-3 py-2.5">
          <div class="grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1">
            <button
              id="region-great-britain"
              type="button"
              phx-click="region"
              phx-value-region="great-britain"
              class="rounded-lg bg-white px-2 py-1.5 text-[10px] font-semibold text-slate-700 shadow-sm transition hover:text-slate-950 active:scale-[0.98]"
            >
              Great Britain
            </button>
            <button
              id="region-northeast-corridor"
              type="button"
              phx-click="region"
              phx-value-region="northeast-corridor"
              class="rounded-lg px-2 py-1.5 text-[10px] font-semibold text-slate-500 transition hover:bg-white hover:text-slate-950 hover:shadow-sm active:scale-[0.98]"
            >
              Northeast Corridor
            </button>
          </div>
        </footer>
      </aside>

      <button
        :if={!@legend_open?}
        id="show-map-legend"
        type="button"
        phx-click="toggle-legend"
        aria-label="Show map legend"
        class="absolute top-3 left-3 flex items-center gap-2 rounded-2xl border border-white/80 bg-white/90 px-3 py-2.5 text-xs font-bold text-slate-800 shadow-lg backdrop-blur-xl transition hover:bg-white hover:shadow-xl active:scale-[0.97] sm:top-5 sm:left-5"
      >
        <span class="grid size-7 place-items-center rounded-lg bg-slate-950 text-white">
          <.icon name="hero-map" class="size-4" />
        </span>
        Legend
      </button>
    </div>
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
