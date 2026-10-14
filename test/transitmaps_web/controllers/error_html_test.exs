defmodule TransitmapsWeb.ErrorHTMLTest do
  use TransitmapsWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html as a full-page state with a way back" do
    html = render_to_string(TransitmapsWeb.ErrorHTML, "404", "html", [])

    assert html =~ "Page not found"
    assert html =~ ~s(class="ui-page-state")
    assert html =~ ~s(href="/")
  end

  test "renders 500.html" do
    assert render_to_string(TransitmapsWeb.ErrorHTML, "500", "html", []) =~ "Server error"
  end
end
