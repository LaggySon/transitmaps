defmodule TransitmapsWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  Each error is a full-page state (DESIGN.md section 7.25): the top bar stays,
  so the visitor can get back to the map, and the page says what happened.

  See config/config.exs.
  """
  use TransitmapsWeb, :html

  def render(template, _assigns) do
    {title, message} = explain(template)
    error_page(%{title: title, message: message})
  end

  defp explain("404" <> _), do: {"Page not found", "There is no page at this address."}

  defp explain("500" <> _),
    do:
      {"Server error", "The server failed to answer this request. Reload the page to try again."}

  defp explain(template),
    do: {Phoenix.Controller.status_message_from_template(template), "This request failed."}

  defp error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="light dark" />
        <title>{@title} · Transit Maps</title>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body>
        <div class="ui-shell">
          <header class="ui-topbar">
            <a class="ui-brand" href="/">
              <span class="ui-brand-mark" aria-hidden="true"></span>Transit Maps
            </a>
          </header>
          <main id="main" class="ui-main">
            <div class="ui-page-state" data-status="failure" role="alert">
              <h1 class="ui-page-state-title">{@title}</h1>
              <p>{@message}</p>
              <a class="ui-button" href="/">Open the map</a>
            </div>
          </main>
        </div>
      </body>
    </html>
    """
  end
end
