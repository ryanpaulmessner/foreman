# Hermetic: the suite never reads the operator's ~/.config/foreman (it maps this checkout's
# path to a ticket prefix, which flips CLI tests into file mode). Tests needing config set their own.
config_dir =
  Path.join(System.tmp_dir!(), "foreman-test-config-#{System.unique_integer([:positive])}")

File.mkdir_p!(config_dir)
System.put_env("FOREMAN_CONFIG_DIR", config_dir)

Mimic.copy(Phoenix.Token)
Mimic.copy(File)
Mimic.copy(Foreman.SessionTmux)

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Foreman.Repo, :manual)
Foreman.TestDatabase.assert_clean!()
ExUnit.after_suite(fn _ -> Foreman.TestDatabase.assert_clean!() end)
