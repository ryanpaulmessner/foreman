import Config

config :foreman,
  runtime_enabled: false,
  session_prompt_fallback: true,
  session_prompt_directory: Path.expand("../test/fixtures/session-launch", __DIR__),
  config_directory: "/tmp/bb-exec/test-config"

# Jobs are inserted into the SQL sandbox and explicitly executed by tests.
config :foreman, Oban, testing: :manual, queues: false, plugins: false

# __DIR__ identifies this checkout even when Mix runs from a subdirectory.
checkout = Path.basename(Path.expand("..", __DIR__))

config :foreman, Foreman.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "foreman_test_#{checkout}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :foreman, ForemanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "XpXh35U5zufk/ie8TVsOdH9LT/rQtWa0c+B3iwL5wYJbxuvM/4eSZcQckn8JhiIO",
  server: false

# In test we don't send emails
config :foreman, Foreman.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
