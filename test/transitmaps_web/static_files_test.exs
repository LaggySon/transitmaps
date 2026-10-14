defmodule TransitmapsWeb.StaticFilesTest do
  use TransitmapsWeb.ConnCase, async: true

  # The root layout links icons through ~p, which in production names the
  # digested copy phx.digest writes (favicon-<hash>.svg). Those names must be
  # served like the originals, or every page shows the browser's blank icon.
  test "serves a digested favicon", %{conn: conn} do
    name = "favicon-#{System.unique_integer([:positive])}.svg"
    path = Application.app_dir(:transitmaps, Path.join("priv/static", name))
    File.write!(path, File.read!(Application.app_dir(:transitmaps, "priv/static/favicon.svg")))
    on_exit(fn -> File.rm(path) end)

    conn = get(conn, "/" <> name)

    assert conn.status == 200
    assert conn.resp_body =~ "<svg"
  end
end
