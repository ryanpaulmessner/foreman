defmodule Foreman.PaneEnvironmentTest do
  use ExUnit.Case, async: false
  alias Foreman.SessionTmux

  test "service client environment does not reach new sessions, new windows or respawned panes" do
    socket = Foreman.TestTmux.socket("fm-pane-env")
    dir = Path.expand("tmp/#{socket}")
    File.mkdir_p!(dir)
    tmux = System.find_executable("tmux")

    {clean, expected} = pane_environment(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    File.mkdir_p!(Path.join(dir, "tickets"))
    File.cp!("tickets/fm-3c3.7.md", Path.join(dir, "tickets/fm-3c3.7.md"))

    removed =
      for {key, _} <- System.get_env(),
          not Map.has_key?(clean, key),
          do: {String.to_charlist(key), false}

    port =
      Port.open({:spawn_executable, tmux}, [
        :binary,
        :exit_status,
        args: ["-D", "-L", socket, "-f", "/dev/null"],
        env:
          removed ++
            Enum.map(clean, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    old = System.get_env()

    on_exit(fn ->
      System.cmd(tmux, ["-L", socket, "kill-server"], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
      for key <- Map.keys(System.get_env()) -- Map.keys(old), do: System.delete_env(key)
      System.put_env(old)
      File.rm_rf!(dir)
    end)

    assert eventually(fn ->
             elem(
               System.cmd(tmux, ["-N", "-L", socket, "show-environment", "-g"],
                 stderr_to_stdout: true
               ),
               1
             ) == 0
           end)

    executable = Path.join(dir, "claude")

    File.write!(
      executable,
      "#!/bin/sh\nenv -0 > env\nprintf '%s\\n' \"$@\" > argv\ncommand -v foreman > foreman-path\ncommand -v mix > mix-path\nforeman ls --json > tickets.json\nprintf ready > ready\nread line\n"
    )

    File.chmod!(executable, 0o700)
    System.put_env("PATH", "/fake/releases/test/erts/bin:/fake/releases/test/bin:" <> old["PATH"])
    System.put_env("FOREMAN_DATABASE_URL", "test-only")
    System.put_env("RELEASE_ROOT", "/fake/releases/test")
    System.put_env("PHX_SERVER", "true")
    System.put_env("SECRET_KEY_BASE", "test-only")

    session = %{
      project: "sample",
      ticket: "pane-1",
      session_id: Ecto.UUID.generate(),
      workdir: dir
    }

    opts = [socket: socket, executable: executable]

    File.write!(
      "tmp/pane-environment-transcript.txt",
      "Server: tmux -D -L <scratch> -f /dev/null; clean HOME/USER/LOGNAME/SHELL, PATH=/usr/bin:/bin\nClient: fake release PATH plus FOREMAN_DATABASE_URL, RELEASE_ROOT, PHX_SERVER, SECRET_KEY_BASE\n"
    )

    assert {:ok, first} = SessionTmux.launch(session, "probe", opts)
    check_pane(dir, socket, first, expected)
    File.rm!(Path.join(dir, "ready"))

    assert {:ok, second} =
             SessionTmux.launch(
               %{session | ticket: "pane-2", session_id: Ecto.UUID.generate()},
               "probe",
               opts
             )

    check_pane(dir, socket, second, expected)
    File.rm!(Path.join(dir, "ready"))

    {pane, 0} =
      System.cmd(tmux, ["-L", socket, "display-message", "-p", "-t", second, ~S(#{pane_id})])

    System.cmd(tmux, ["-L", socket, "rename-window", "-t", second, "coordinator"])

    coordinator =
      %{session | project: "__foreman__", ticket: "coordinator"} |> Map.put(:window, second)

    File.write!(Path.join(dir, "pause-login"), "")

    System.cmd(tmux, [
      "-L",
      socket,
      "set-option",
      "-w",
      "-t",
      second,
      "automatic-rename-format",
      "coordinator"
    ])

    System.cmd(tmux, ["-L", socket, "set-option", "-w", "-t", second, "automatic-rename", "on"])
    assert :ok = SessionTmux.respawn_coordinator(coordinator, :new, String.trim(pane), opts)

    assert {"off\n", 0} =
             System.cmd(tmux, [
               "-L",
               socket,
               "show-options",
               "-wv",
               "-t",
               second,
               "automatic-rename"
             ])

    if Map.has_key?(expected, :auth_socket) do
      System.cmd(tmux, ["-L", socket, "send-keys", "-t", second, "Enter"])
    end

    check_pane(dir, socket, second, expected)

    assert {"coordinator\n", 0} =
             System.cmd(tmux, [
               "-L",
               socket,
               "display-message",
               "-p",
               "-t",
               second,
               ~S(#{window_name})
             ])

    File.write!(
      "tmp/pane-environment-transcript.txt",
      "respawn window name: coordinator (unchanged)\n",
      [:append]
    )
  end

  defp pane_environment(dir) do
    if System.get_env("FOREMAN_HOST_ACCEPTANCE") == "1" do
      clean =
        Map.take(System.get_env(), ~w(HOME USER LOGNAME SHELL))
        |> Map.put("PATH", "/usr/bin:/bin")

      {clean,
       %{
         foreman: Path.expand("~/.local/bin/foreman"),
         mix: Path.expand("~/.asdf/shims/mix"),
         shell: Path.basename(clean["SHELL"])
       }}
    else
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      for command <- ["foreman", "mix"] do
        path = Path.join(bin, command)
        File.write!(path, "#!/bin/sh\nprintf '%s\\n' '[{\"id\":\"fm-3c3.7\"}]'\n")
        File.chmod!(path, 0o700)
      end

      shell = Path.join(dir, "login-shell")

      File.write!(shell, """
      #!/bin/sh
      case "$1" in
        -ilc) if [ -f '#{dir}/pause-login' ]; then read line; fi
              export PATH='#{bin}:/usr/bin:/bin'
              export RELEASE_LOGIN_ONLY=test PHX_LOGIN_ONLY=test FOREMAN_DATABASE_URL=test
              exec /bin/sh -c "$2" ;;
        -c) exec /bin/sh -c "$2" ;;
        -l) printf ready > '#{dir}/shell-returned'; exec /bin/sh ;;
        *) exit 1 ;;
      esac
      """)

      File.chmod!(shell, 0o700)

      {%{
         "HOME" => dir,
         "USER" => System.get_env("USER"),
         "SHELL" => shell,
         "PATH" => "/usr/bin:/bin",
         "SSH_AUTH_SOCK" => "/fixture/ssh-agent",
         "DISPLAY" => ":42"
       },
       %{
         foreman: Path.join(bin, "foreman"),
         mix: Path.join(bin, "mix"),
         shell: "sh",
         auth_socket: "/fixture/ssh-agent"
       }}
    end
  end

  defp check_pane(dir, socket, window, expected) do
    assert eventually(fn -> File.exists?(Path.join(dir, "ready")) end)
    env = File.read!(Path.join(dir, "env"))

    for forbidden <- [
          "/releases/",
          "FOREMAN_DATABASE_URL=",
          "RELEASE_",
          "PHX_",
          "SECRET_KEY_BASE="
        ] do
      assert not String.contains?(env, forbidden), "pane environment contains #{forbidden}"
    end

    if Map.has_key?(expected, :auth_socket) do
      assert String.contains?(env, "SSH_AUTH_SOCK=#{expected.auth_socket}\0")
      assert String.contains?(env, "DISPLAY=:42\0")
    end

    assert String.trim(File.read!(Path.join(dir, "foreman-path"))) == expected.foreman
    assert String.trim(File.read!(Path.join(dir, "mix-path"))) == expected.mix

    assert {:ok, [%{"id" => "fm-3c3.7"}]} =
             Jason.decode(File.read!(Path.join(dir, "tickets.json")))

    argv = File.read!(Path.join(dir, "argv")) |> String.split("\n", trim: true)
    [flag, id, "--settings", settings, prompt] = argv
    assert Jason.decode!(settings)["hooks"]["StopFailure"]

    File.write!(
      "tmp/pane-environment-transcript.txt",
      "\nwindow=#{window}\nargv=#{flag} #{id} --settings <per-launch hooks> #{prompt}\n" <>
        "command -v foreman: " <>
        File.read!(Path.join(dir, "foreman-path")) <>
        "command -v mix: " <>
        File.read!(Path.join(dir, "mix-path")) <>
        "foreman ls --json: parsed one local fixture ticket, fm-3c3.7\n" <>
        "env names (values withheld): " <>
        (env
         |> String.split("\0", trim: true)
         |> Enum.map(&(String.split(&1, "=", parts: 2) |> hd()))
         |> Enum.sort()
         |> Enum.join(", ")) <>
        "\nNo release paths or service-only variables.\n",
      [:append]
    )

    System.cmd("tmux", ["-L", socket, "send-keys", "-t", window, "Enter"])

    assert eventually(fn ->
             elem(
               System.cmd("tmux", [
                 "-L",
                 socket,
                 "display-message",
                 "-p",
                 "-t",
                 window,
                 ~S(#{pane_current_command})
               ]),
               0
             ) == expected.shell <> "\n"
           end)

    if Map.has_key?(expected, :auth_socket) do
      assert eventually(fn -> File.exists?(Path.join(dir, "shell-returned")) end)
      File.rm!(Path.join(dir, "shell-returned"))
    end

    File.write!(
      "tmp/pane-environment-transcript.txt",
      "after stub exit, pane_current_command: #{expected.shell}\n",
      [:append]
    )
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(_, 0), do: false

  defp eventually(fun, tries) do
    if fun.(),
      do: true,
      else:
        (receive do
         after
           25 -> eventually(fun, tries - 1)
         end)
  end
end
