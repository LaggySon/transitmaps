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
        class="absolute inset-0"
      >
      </div>

      <div class="absolute top-4 left-4 w-64 rounded-2xl bg-base-100/95 shadow-xl backdrop-blur p-4 space-y-1">
        <h1 class="text-lg font-bold pb-1">Transit</h1>

        <label
          :for={{cat, label} <- mode_labels()}
          class={["flex items-center gap-3 rounded-lg px-2 py-1.5",
                  route_count(@counts, cat) == 0 && "opacity-40" || "cursor-pointer hover:bg-base-200"]}
        >
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            checked={MapSet.member?(@enabled, cat)}
            disabled={route_count(@counts, cat) == 0}
            phx-click="toggle"
            phx-value-cat={cat}
          />
          <span class="inline-block h-3 w-3 rounded-full" style={"background: #{RouteTypes.default_color(cat)}"}></span>
          <span class="flex-1 text-sm">{label}</span>
          <span class="text-xs opacity-60">{route_count(@counts, cat)}</span>
        </label>

        <p :if={@counts == %{}} class="text-xs opacity-70 pt-2">
          No feeds imported yet. Run
          <code class="font-mono">mix gtfs.import &lt;name&gt; &lt;gtfs-zip-url&gt;</code>
        </p>
      </div>
    </div>
    """
  end

  defp route_count(counts, cat), do: Map.get(counts, cat, 0)
end
