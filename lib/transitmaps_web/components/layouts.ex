defmodule TransitmapsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TransitmapsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the page shell from DESIGN.md section 5.2: a skip link, the top bar
  with the brand and an aside, then `main`. The page fills the window and
  each page lays out its own content inside `main`.

  ## Examples

      <Layouts.app flash={@flash}>
        <:aside>3 agencies</:aside>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :aside, doc: "global readouts on the right of the top bar"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a class="ui-skip-link" href="#main">Skip to the map</a>
    <div id="app-shell" class="ui-shell ui-shell--fill">
      <header class="ui-topbar">
        <span class="ui-brand">
          <span class="ui-brand-mark" aria-hidden="true"></span>Transit Maps
        </span>
        <div class="ui-topbar-aside">
          {render_slot(@aside)}
        </div>
      </header>
      <div id="connection-lost" class="ui-notice tm-connection" data-status="warning" role="alert">
        Connection lost. Reconnecting…
      </div>
      <.flash_group flash={@flash} />
      <main id="main" class="ui-main tm-main">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc """
  Shows the flash messages as notices at the top of the page, under the top
  bar. They stay until the visitor dismisses them.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
