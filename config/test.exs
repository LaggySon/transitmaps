import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :transitmaps, Transitmaps.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "transitmaps_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Cached API responses would leak data between sandboxed tests.
config :transitmaps, :geojson_cache, false

# Never poll the live TfL API during tests (or the Playwright test server).
config :transitmaps, Transitmaps.Live.Server, enabled: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :transitmaps, TransitmapsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "fRaU7NlNytagAwuo2wmy6mr0YqgdevJ0h3sup3LnynI0TGJSdYwffzEMAN7azEDH",
  server: false

# In test we don't send emails
config :transitmaps, Transitmaps.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
