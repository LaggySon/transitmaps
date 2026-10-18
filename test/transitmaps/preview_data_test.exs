defmodule Transitmaps.PreviewDataTest do
  use ExUnit.Case, async: false

  alias Transitmaps.PreviewData

  @create_tables [
    """
    CREATE TABLE feeds (
      id bigserial PRIMARY KEY,
      name varchar NOT NULL,
      url varchar(1000),
      imported_at timestamp(0),
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL
    )
    """,
    """
    CREATE TABLE routes (
      id bigserial PRIMARY KEY,
      feed_id bigint NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
      route_id varchar NOT NULL,
      agency_name varchar,
      short_name varchar,
      long_name varchar(500),
      route_type integer NOT NULL,
      category varchar NOT NULL,
      color varchar,
      text_color varchar,
      geometry jsonb,
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL
    )
    """,
    """
    CREATE TABLE stops (
      id bigserial PRIMARY KEY,
      feed_id bigint NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
      stop_id varchar NOT NULL,
      name varchar(500),
      lat double precision NOT NULL,
      lon double precision NOT NULL,
      location_type integer DEFAULT 0,
      categories varchar[] NOT NULL DEFAULT '{}',
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL,
      lines jsonb[] NOT NULL DEFAULT '{}'
    )
    """
  ]

  setup do
    repo_config = Application.fetch_env!(:transitmaps, Transitmaps.Repo)
    suffix = System.unique_integer([:positive])
    source_database = "transitmaps_preview_source_#{suffix}"
    destination_database = "transitmaps_preview_destination_#{suffix}"

    admin_options = connection_options(repo_config, "postgres")

    admin =
      start_supervised!(
        Supervisor.child_spec({Postgrex, admin_options},
          id: {:preview_data_admin, suffix},
          restart: :temporary
        )
      )

    Postgrex.query!(admin, ~s(CREATE DATABASE "#{source_database}"), [])
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{destination_database}"), [])

    on_exit(fn ->
      {:ok, cleanup_connection} = Postgrex.start_link(admin_options)

      try do
        Postgrex.query!(cleanup_connection, ~s(DROP DATABASE "#{source_database}"), [])
        Postgrex.query!(cleanup_connection, ~s(DROP DATABASE "#{destination_database}"), [])
      after
        GenServer.stop(cleanup_connection)
      end
    end)

    source_url = database_url(repo_config, source_database)
    destination_url = database_url(repo_config, destination_database)

    create_schema!(repo_config, source_database, suffix)
    create_schema!(repo_config, destination_database, suffix)

    %{source_url: source_url, destination_url: destination_url, repo_config: repo_config}
  end

  test "streams all GTFS tables and advances destination sequences", context do
    with_connection("source_fixture", context.source_url, fn source ->
      Postgrex.query!(
        source,
        """
        INSERT INTO feeds (id, name, url, imported_at, inserted_at, updated_at)
        VALUES (7, 'main-feed', 'https://example.test/feed.zip', NOW(), NOW(), NOW())
        """,
        []
      )

      Postgrex.query!(
        source,
        """
        INSERT INTO routes (
          id, feed_id, route_id, agency_name, short_name, long_name, route_type,
          category, color, text_color, geometry, inserted_at, updated_at
        ) VALUES (
          11, 7, 'route-1', 'Main Railway', 'M1', 'Main line', 2,
          'rail', '123456', 'ffffff', '{"type":"MultiLineString","coordinates":[]}',
          NOW(), NOW()
        )
        """,
        []
      )

      Postgrex.query!(
        source,
        """
        INSERT INTO stops (
          id, feed_id, stop_id, name, lat, lon, location_type, categories,
          inserted_at, updated_at, lines
        ) VALUES (
          13, 7, 'stop-1', 'Main Station', 51.5, -0.1, 1, ARRAY['rail'],
          NOW(), NOW(), ARRAY['{"name":"M1","color":"123456"}'::jsonb]
        )
        """,
        []
      )
    end)

    assert :ok = PreviewData.clone!(context.source_url, context.destination_url)

    assert_raise ArgumentError, ~r/must differ/, fn ->
      PreviewData.clone!(context.source_url, context.source_url)
    end

    with_connection("destination_assertions", context.destination_url, fn destination ->
      assert Postgrex.query!(destination, "SELECT name FROM feeds", []).rows == [["main-feed"]]
      assert Postgrex.query!(destination, "SELECT route_id FROM routes", []).rows == [["route-1"]]
      assert Postgrex.query!(destination, "SELECT stop_id FROM stops", []).rows == [["stop-1"]]

      assert Postgrex.query!(
               destination,
               "INSERT INTO feeds (name, inserted_at, updated_at) VALUES ('next', NOW(), NOW()) RETURNING id",
               []
             ).rows == [[8]]
    end)
  end

  defp create_schema!(repo_config, database, suffix) do
    url = database_url(repo_config, database)

    with_connection("schema_#{database}_#{suffix}", url, fn connection ->
      Enum.each(@create_tables, &Postgrex.query!(connection, &1, []))
    end)
  end

  defp with_connection(id, url, function) do
    options =
      url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.delete(:scheme)

    child_id = {:preview_data_connection, id}

    connection =
      start_supervised!(
        Supervisor.child_spec({Postgrex, options}, id: child_id, restart: :temporary)
      )

    try do
      function.(connection)
    after
      stop_supervised!(child_id)
    end
  end

  defp connection_options(repo_config, database) do
    repo_config
    |> Keyword.take([:username, :password, :hostname, :port, :socket_options])
    |> Keyword.put(:database, database)
  end

  defp database_url(repo_config, database) do
    username = URI.encode_www_form(Keyword.fetch!(repo_config, :username))
    password = URI.encode_www_form(Keyword.fetch!(repo_config, :password))
    hostname = Keyword.fetch!(repo_config, :hostname)
    port = Keyword.get(repo_config, :port, 5432)

    "ecto://#{username}:#{password}@#{hostname}:#{port}/#{database}"
  end
end
