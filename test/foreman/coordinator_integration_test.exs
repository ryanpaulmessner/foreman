defmodule Foreman.CoordinatorIntegrationTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Sessions, SessionTmux}
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint ForemanWeb.Endpoint

  setup_all do
    Mix.Task.run("escript.build", ["--no-compile"])
    :ok
  end

  setup do
    name = Foreman.TestTmux.socket("fm-coordinator-test")
    dir = Path.expand("tmp/#{name}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".zshrc"), "")
    socket = name
    token = Path.join(dir, "token")
    File.write!(token, "scratch-coordinator-test-token")

    File.write!(
      Path.join(dir, "claude"),
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > argv\npwd > cwd\nprintf 'CLAUDE %s %s; prompt=/orient\\n' \"$1\" \"$2\"\n"
    )

    File.chmod!(Path.join(dir, "claude"), 0o700)
    File.ln_s!(Path.expand("foreman"), Path.join(dir, "foreman"))
    old_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> old_path)

    old =
      for key <- [:planning_tmux_socket, :coordinator_workdir, :token_file],
          into: %{},
          do: {key, Application.get_env(:foreman, key)}

    Application.put_env(:foreman, :planning_tmux_socket, socket)
    Application.put_env(:foreman, :coordinator_workdir, dir)
    Application.put_env(:foreman, :token_file, token)

    {_, 0} =
      System.cmd(
        "tmux",
        [
          "-L",
          socket,
          "-f",
          "/dev/null",
          "new-session",
          "-x",
          "500",
          "-y",
          "30",
          "-d",
          "-s",
          "coordinator",
          "-n",
          "coordinator",
          "-c",
          dir,
          "/bin/sh"
        ],
        env: [{"ZDOTDIR", dir}]
      )

    {socket, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "display-message",
        "-p",
        "-t",
        "coordinator",
        ~S(#{socket_path})
      ])

    socket = String.trim(socket)

    {pane, 0} =
      System.cmd("tmux", [
        "-S",
        socket,
        "display-message",
        "-p",
        "-t",
        "coordinator",
        ~S(#{pane_id})
      ])

    server = start_supervised!({Bandit, plug: ForemanWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    old_url = System.get_env("FOREMAN_URL")
    System.put_env("FOREMAN_URL", "http://127.0.0.1:#{port}")

    on_exit(fn ->
      System.cmd("tmux", ["-S", socket, "kill-server"], stderr_to_stdout: true)
      System.put_env("PATH", old_path)

      if old_url,
        do: System.put_env("FOREMAN_URL", old_url),
        else: System.delete_env("FOREMAN_URL")

      for {key, value} <- old do
        if value,
          do: Application.put_env(:foreman, key, value),
          else: Application.delete_env(:foreman, key)
      end

      File.rm_rf!(dir)
    end)

    %{
      dir: dir,
      socket: socket,
      pane: String.trim(pane),
      token: token,
      url: "http://127.0.0.1:#{port}"
    }
  end

  test "real in-pane CLI starts, resumes, freshens and adopts; coordinator never parks", c do
    launch(c, "")
    first = Sessions.coordinator()
    assert ["--session-id", id, "--settings", settings, "/orient"] = argv(c)
    assert id == first.session_id
    assert Jason.decode!(settings)["hooks"]["StopFailure"]
    assert String.trim(File.read!(Path.join(c.dir, "cwd"))) == c.dir

    assert {"coordinator\n", 0} =
             System.cmd("tmux", [
               "-S",
               c.socket,
               "display-message",
               "-p",
               "-t",
               c.pane,
               ~S(#{window_name})
             ])

    launch(c, "")
    assert ["--resume", ^id, "--settings", _, "/orient"] = argv(c)
    assert Sessions.coordinator().session_id == id

    launch(c, "--fresh")
    assert ["--session-id", fresh, "--settings", _, "/orient"] = argv(c)
    refute fresh == id
    assert Sessions.coordinator().session_id == fresh

    Sessions.reconcile(idle_timeout: 0)
    assert Sessions.coordinator().state == :ended
    assert {:ok, %{state: :ended}} = SessionTmux.observe(Sessions.coordinator())
    adopted = "1edc88cf-b665-4ce3-adc4-f1bd434c64f2"

    assert {output, 0} =
             System.cmd(Path.expand("foreman"), ["coordinator", "--adopt", adopted], env: env(c))

    assert String.trim(output) == adopted

    File.write!(
      Path.join(c.dir, "transcript"),
      "\nforeman coordinator --adopt #{adopted}\n#{output}",
      [:append]
    )

    launch(c, "")
    assert ["--resume", ^adopted, "--settings", _, "/orient"] = argv(c)
    assert Sessions.coordinator().session_id == adopted

    transcript =
      "scratch_socket=#{Path.basename(c.socket)}\nfirst=#{id}\nfresh=#{fresh}\nadopted=#{adopted}\n" <>
        "resume/fresh/adopt argv and /orient verified through real escript + HTTP + scratch tmux\n" <>
        "window name after foreman coordinator: coordinator (unchanged)\n" <>
        File.read!(Path.join(c.dir, "transcript"))

    File.mkdir_p!("tmp")
    File.write!("tmp/coordinator-transcript.txt", transcript)
  end

  test "board focus and relaunch preserve identity; usage-limit wait reaches Needs you and Continue",
       c do
    launch(c, "")
    id = Sessions.coordinator().session_id
    {:ok, view, _} = live(Phoenix.ConnTest.build_conn(), "/")

    {other, 0} =
      System.cmd("tmux", [
        "-S",
        c.socket,
        "new-window",
        "-t",
        "=coordinator:",
        "-P",
        "-F",
        ~S(#{window_id}),
        "/bin/sh"
      ])

    view |> element("#coordinator-focus") |> render_click()

    {focused, 0} =
      System.cmd("tmux", [
        "-S",
        c.socket,
        "display-message",
        "-p",
        "-t",
        "coordinator",
        ~S(#{window_id})
      ])

    assert String.trim(focused) == Sessions.coordinator().window
    refute focused == other

    File.write!(
      Path.join(c.dir, "claude"),
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > argv\nread line\nprintf '%s' \"$line\" > continued\n"
    )

    Sessions.reconcile()
    send(view.pid, :reconcile)
    view |> element("#coordinator-relaunch") |> render_click()

    assert eventually(fn ->
             match?({:ok, %{state: :running}}, SessionTmux.observe(Sessions.coordinator()))
           end)

    assert ["--resume", ^id, "--settings", _, "/orient"] = argv(c)
    assert Sessions.prepare_coordinator(:fresh) == {:error, :coordinator_active}

    ["--resume", ^id, "--settings", settings, "/orient"] = argv(c)
    [entry] = Jason.decode!(settings)["hooks"]["StopFailure"]
    [hook] = entry["hooks"]
    command = "printf '%s' '{\"error\":\"rate_limit\"}' | " <> hook["command"]

    assert {_, 0} =
             System.cmd("/bin/sh", ["-c", command],
               env: [
                 {"FOREMAN_URL", "http://127.0.0.1:1"},
                 {"FOREMAN_TOKEN_FILE", "/missing/token"}
               ]
             )

    [request] = Foreman.SessionWaiting.pending(Sessions.coordinator_key(), id)
    request_id = request.id
    assert request.facts["reason"] == "usage_limit"
    assert request.facts["provider"] == "Anthropic"

    {:ok, inbox, _} = live(Phoenix.ConnTest.build_conn(), "/needs-you")
    assert has_element?(inbox, "[id*='#{request_id}']")
    assert {:ok, _} = Foreman.SessionWaiting.continue(request_id)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "continued")) end)
    assert File.read!(Path.join(c.dir, "continued")) == "continue"
    Sessions.reconcile(idle_timeout: 0)
    assert Sessions.coordinator().state == :ended
  end

  defp argv(c), do: File.read!(Path.join(c.dir, "argv")) |> String.split("\n", trim: true)
  defp env(c), do: [{"FOREMAN_URL", c.url}, {"FOREMAN_TOKEN_FILE", c.token}]

  defp launch(c, flags) do
    File.rm(Path.join(c.dir, "argv"))

    command =
      "FOREMAN_URL='#{c.url}' FOREMAN_TOKEN_FILE='#{c.token}' '#{Path.expand("foreman")}' coordinator #{flags}"

    {_, 0} = System.cmd("tmux", ["-S", c.socket, "send-keys", "-t", c.pane, "-l", command])
    {_, 0} = System.cmd("tmux", ["-S", c.socket, "send-keys", "-t", c.pane, "Enter"])

    assert eventually(fn ->
             File.exists?(Path.join(c.dir, "argv")) and
               match?({:ok, %{state: :ended}}, SessionTmux.observe(Sessions.coordinator()))
           end),
           capture(c)

    transcript =
      capture(c)
      |> String.trim()
      |> Kernel.<>("\n")
      |> String.replace(c.dir, "<scratch>")
      |> String.replace(File.cwd!(), "<checkout>")

    File.write!(
      Path.join(c.dir, "transcript"),
      "\nforeman coordinator #{flags}\n" <> transcript,
      [:append]
    )
  end

  defp capture(c),
    do: elem(System.cmd("tmux", ["-S", c.socket, "capture-pane", "-p", "-t", c.pane]), 0)

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
