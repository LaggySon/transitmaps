defmodule TransitmapsWeb.HealthController do
  use TransitmapsWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      commit: System.get_env("RAILWAY_GIT_COMMIT_SHA"),
      disk_free_mb: disk_free_mb(System.tmp_dir!())
    })
  end

  # Imports unpack feeds of several gigabytes into the temporary directory;
  # a full disk truncates downloads, so the space left is worth seeing.
  defp disk_free_mb(dir) do
    with {output, 0} <- System.cmd("df", ["-Pk", dir], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, _blocks, _used, available | _] <- String.split(line),
         {kb, ""} <- Integer.parse(available) do
      div(kb, 1024)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
