defmodule Transitmaps.PreviewData do
  @moduledoc """
  Copies the complete GTFS data set from the main Railway database into an
  isolated preview database.

  The copy is streamed between PostgreSQL connections, so even the national
  rail data set is never held in application memory. The destination changes
  happen in one transaction and the source is read through one repeatable-read
  snapshot.
  """

  require Logger

  @tables [
    {"feeds", ~w(id name url imported_at inserted_at updated_at)},
    {"routes",
     ~w(id feed_id route_id agency_name short_name long_name route_type category color text_color geometry inserted_at updated_at)},
    {"stops",
     ~w(id feed_id stop_id name lat lon location_type categories inserted_at updated_at lines)}
  ]

  @doc """
  Replaces the destination GTFS tables with a consistent snapshot of source.

  Both URLs use Ecto's standard URL format. The source account only needs
  `CONNECT`, schema `USAGE`, and `SELECT` access to the three GTFS tables.
  """
  def clone!(source_url, destination_url)
      when is_binary(source_url) and is_binary(destination_url) do
    ensure_distinct_urls!(source_url, destination_url)
    {:ok, _apps} = Application.ensure_all_started(:postgrex)

    source = start_connection!(source_url, [])

    destination =
      start_connection!(destination_url,
        socket_options: destination_socket_options()
      )

    try do
      ensure_distinct_databases!(source, destination)
      clone_tables!(source, destination)
    after
      stop_connection(source)
      stop_connection(destination)
    end
  end

  defp clone_tables!(source, destination) do
    {:ok, copied_rows} =
      Postgrex.transaction(
        source,
        fn source_connection ->
          Postgrex.query!(
            source_connection,
            "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
            []
          )

          {:ok, copied_rows} =
            Postgrex.transaction(
              destination,
              fn destination_connection ->
                Postgrex.query!(
                  destination_connection,
                  "TRUNCATE TABLE stops, routes, feeds RESTART IDENTITY CASCADE",
                  []
                )

                copied_rows =
                  Map.new(@tables, fn {table, columns} ->
                    {table,
                     copy_table!(
                       source_connection,
                       destination_connection,
                       table,
                       columns
                     )}
                  end)

                reset_sequences!(destination_connection)
                copied_rows
              end,
              timeout: :infinity
            )

          copied_rows
        end,
        timeout: :infinity
      )

    Logger.info(
      "Cloned main GTFS data into preview database: " <>
        Enum.map_join(@tables, ", ", fn {table, _columns} ->
          "#{table}=#{Map.fetch!(copied_rows, table)}"
        end)
    )

    :ok
  end

  defp copy_table!(source, destination, table, columns) do
    column_list = Enum.join(columns, ", ")
    copy_out = Postgrex.stream(source, "COPY #{table} (#{column_list}) TO STDOUT BINARY", [])
    copy_in = Postgrex.stream(destination, "COPY #{table} (#{column_list}) FROM STDIN BINARY", [])

    Enum.into(copy_out, copy_in, fn %Postgrex.Result{rows: rows} -> rows end)

    %Postgrex.Result{rows: [[num_rows]]} =
      Postgrex.query!(destination, "SELECT COUNT(*) FROM #{table}", [])

    num_rows
  end

  defp reset_sequences!(connection) do
    Enum.each(@tables, fn {table, _columns} ->
      Postgrex.query!(
        connection,
        """
        SELECT setval(
          pg_get_serial_sequence('#{table}', 'id'),
          COALESCE(MAX(id), 1),
          MAX(id) IS NOT NULL
        )
        FROM #{table}
        """,
        []
      )
    end)
  end

  defp start_connection!(url, extra_options) do
    options =
      url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.delete(:scheme)
      |> Keyword.merge(extra_options)
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.put(:connect_timeout, 15_000)

    {:ok, connection} = Postgrex.start_link(options)
    connection
  end

  defp destination_socket_options do
    if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  end

  defp ensure_distinct_urls!(source_url, destination_url) do
    if source_url == destination_url do
      raise ArgumentError, "GTFS source and preview destination database URLs must differ"
    end
  end

  defp ensure_distinct_databases!(source, destination) do
    if database_identity(source) == database_identity(destination) do
      raise ArgumentError, "GTFS source and preview destination resolve to the same database"
    end
  end

  defp database_identity(connection) do
    %Postgrex.Result{rows: [[database, system_identifier]]} =
      Postgrex.query!(
        connection,
        "SELECT current_database(), system_identifier::text FROM pg_control_system()",
        []
      )

    {database, system_identifier}
  end

  defp stop_connection(connection) do
    if Process.alive?(connection), do: GenServer.stop(connection)
  end
end
