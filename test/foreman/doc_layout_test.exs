defmodule Foreman.DocLayoutTest do
  use ExUnit.Case, async: true
  alias Foreman.DocLayout

  describe "ticket_path/3" do
    test "every fixed name in round 1 has no suffix" do
      for {kind, name} <- [
            {"brief", "brief.md"},
            {"report", "report.md"},
            {"review", "review.md"},
            {"message", "message-r1.md"},
            {"loop", "loop.md"},
            {"pr", "pr.md"},
            {"plan", "plan.md"},
            {"evidence", "evidence"}
          ] do
        assert DocLayout.ticket_path(kind, "fm-x") == {:ok, "builds/fm-x/" <> name}
      end
    end

    test "later rounds add -rN to the rounded kinds" do
      assert DocLayout.ticket_path("brief", "work-8ec.22.1", 2) ==
               {:ok, "builds/work-8ec.22.1/brief-r2.md"}

      assert DocLayout.ticket_path("report", "fm-x", 3) == {:ok, "builds/fm-x/report-r3.md"}
      assert DocLayout.ticket_path("review", "fm-x", 10) == {:ok, "builds/fm-x/review-r10.md"}
      assert DocLayout.ticket_path("message", "fm-x", 4) == {:ok, "builds/fm-x/message-r4.md"}
    end

    test "single-file kinds have no rounds" do
      assert DocLayout.ticket_path("pr", "fm-x", 2) == {:ok, "builds/fm-x/pr.md"}
    end

    test "an unknown kind fails and lists the kinds" do
      assert {:error, message} = DocLayout.ticket_path("notes", "fm-x")
      assert message =~ "brief, message, report, review, loop, pr, plan, evidence"
    end

    test "an invalid ticket id fails" do
      assert {:error, message} = DocLayout.ticket_path("report", "../etc")
      assert message =~ "ticket id"
    end
  end

  describe "next_ticket_path/3" do
    setup do
      root = Path.join(System.tmp_dir!(), "doc-layout-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp touch(root, relative) do
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end

    test "round 1 when the build folder is missing", %{root: root} do
      assert DocLayout.next_ticket_path(root, "brief", "fm-x") == {:ok, "builds/fm-x/brief.md"}

      assert DocLayout.next_ticket_path(root, "message", "fm-x") ==
               {:ok, "builds/fm-x/message-r1.md"}
    end

    test "brief-r3.md when brief.md and brief-r2.md exist", %{root: root} do
      touch(root, "builds/fm-x/brief.md")
      touch(root, "builds/fm-x/brief-r2.md")
      touch(root, "builds/fm-x/report-r7.md")

      assert DocLayout.next_ticket_path(root, "brief", "fm-x") ==
               {:ok, "builds/fm-x/brief-r3.md"}

      assert DocLayout.next_ticket_path(root, "report", "fm-x") ==
               {:ok, "builds/fm-x/report-r8.md"}

      assert DocLayout.next_ticket_path(root, "review", "fm-x") == {:ok, "builds/fm-x/review.md"}
    end

    test "next follows the highest round, not the first gap", %{root: root} do
      touch(root, "builds/fm-x/report-r3.md")

      assert DocLayout.next_ticket_path(root, "report", "fm-x") ==
               {:ok, "builds/fm-x/report-r4.md"}
    end

    test "single-file kinds return their fixed name", %{root: root} do
      touch(root, "builds/fm-x/pr.md")
      assert DocLayout.next_ticket_path(root, "pr", "fm-x") == {:ok, "builds/fm-x/pr.md"}
    end
  end

  describe "note_path/3" do
    test "dated note path for every note kind" do
      for kind <- ~w(research diagnostic audit update message check decision retro) do
        assert DocLayout.note_path(kind, "zoho-timestamps", ~D[2026-11-06]) ==
                 {:ok, "notes/2026-11-06-#{kind}-zoho-timestamps.md"}
      end
    end

    test "an unknown kind fails and lists the allowed kinds" do
      assert {:error, message} = DocLayout.note_path("weird-kind", "x", ~D[2026-11-06])

      assert message =~
               "research, diagnostic, audit, update, message, check, decision, retro"
    end

    test "a bad slug fails and lists the allowed kinds" do
      for slug <- [
            "Zoho",
            "zoho_timestamps",
            "-zoho",
            "zoho-",
            "zoho--ts",
            "",
            String.duplicate("a", 41)
          ] do
        assert {:error, message} = DocLayout.note_path("diagnostic", slug, ~D[2026-11-06])
        assert message =~ "slug"
        assert message =~ "research, diagnostic"
      end

      assert {:ok, _} =
               DocLayout.note_path("diagnostic", String.duplicate("a", 40), ~D[2026-11-06])
    end
  end

  describe "classify/2" do
    test "layout paths are allowed" do
      for path <- [
            "docs/spec.md",
            "docs/specs/doc-layout.md",
            "docs/specs/doc-layout.design.md",
            "docs/specs/doc-layout/mockup/index.html",
            "docs/adr/0001-use-files.md",
            "docs/machines/session.md",
            "builds/work-abc/brief.md",
            "builds/work-abc/brief-r2.md",
            "builds/work-abc/report.md",
            "builds/work-abc/report-r2.md",
            "builds/work-abc/review-r12.md",
            "builds/work-abc/message-r1.md",
            "builds/work-abc/loop.md",
            "builds/work-abc/pr.md",
            "builds/work-abc/plan.md",
            "builds/work-8ec.22.1/evidence/run-1/page.html",
            "notes/2026-11-06-diagnostic-zoho-timestamps.md",
            "handoffs/foreman-board.md",
            "tickets/fm-qpm.1.md"
          ] do
        assert DocLayout.classify(path) == :allowed, path
      end
    end

    test "README, AGENTS, CLAUDE and CHANGELOG are allowed anywhere" do
      for path <- ~w(README.md AGENTS.md lib/x/CLAUDE.md epics/a/AGENTS.md slices/CHANGELOG.md) do
        assert DocLayout.classify(path, legacy: ["slices", "epics"]) == :allowed, path
      end
    end

    test "allow globs" do
      rules = [allow: ["skills/**", "slices/_builder-rules.md", "top/*.md"]]
      assert DocLayout.classify("skills/foreman/SKILL.md", rules) == :allowed

      assert DocLayout.classify("slices/_builder-rules.md", rules ++ [legacy: ["slices"]]) ==
               :allowed

      assert DocLayout.classify("top/a.md", rules) == :allowed
      assert {:refused, _, _} = DocLayout.classify("top/deeper/a.md", rules)
      assert {:refused, _, _} = DocLayout.classify("skillsx/a.md", rules)
    end

    test "names outside the fixed set are refused with a doc path command" do
      assert {:refused, reason, command} = DocLayout.classify("builds/work-abc/notes.md")
      assert reason =~ "builds/work-abc/"
      assert command == "foreman doc path <kind> work-abc"

      for {path, command} <- [
            {"builds/work-abc/report-final.md", "foreman doc path report work-abc --next"},
            {"builds/work-abc/report-r1.md", "foreman doc path report work-abc --next"},
            {"builds/work-abc/brief-r02.md", "foreman doc path brief work-abc --next"},
            {"builds/work-abc/message.md", "foreman doc path message work-abc --next"},
            {"builds/work-abc/loop-r2.md", "foreman doc path loop work-abc"},
            {"builds/work-abc/pr-body.md", "foreman doc path pr work-abc"}
          ] do
        assert {:refused, _, ^command} = DocLayout.classify(path), path
      end

      assert {:refused, _, "foreman doc path report <ticket-id> --next"} =
               DocLayout.classify("builds/Bad_Id/report.md")

      assert {:refused, _, "foreman doc path report <ticket-id> --next"} =
               DocLayout.classify("builds/report.md")
    end

    test "invented names elsewhere get a ticket or note command" do
      rules = [prefixes: ["work", "fm"]]

      assert {:refused, _, "foreman doc path brief work-8ec.22.3 --next"} =
               DocLayout.classify("drafts/briefs/work-8ec.22.3-brief.md", rules)

      assert {:refused, _, "foreman doc path brief <ticket-id> --next"} =
               DocLayout.classify("drafts/briefs/work-8ec.22.3-brief.md")

      assert {:refused, _, "foreman doc path report fm-9mm.15 --next"} =
               DocLayout.classify("docs/sessions/fm-9mm.15-report.md", rules)

      assert {:refused, _, "foreman doc path <kind> fm-9mm.15"} =
               DocLayout.classify("docs/briefs/fm-9mm.15-thing.md", rules)

      assert {:refused, _, "foreman doc path note <kind> zoho-timestamps"} =
               DocLayout.classify("research/zoho_timestamps.md", rules)

      assert {:refused, _, "foreman doc path note audit cache"} =
               DocLayout.classify("docs/audits/cache-audit.md")

      assert {:refused, _, "foreman doc path note message to-ryan"} =
               DocLayout.classify("drafts/message-to-ryan.md")

      assert {:refused, _, "foreman doc path note <kind> <slug>"} =
               DocLayout.classify("docs/__.md/__.md")
    end

    test "bad note, spec and adr names are refused" do
      for path <- [
            "notes/zoho.md",
            "notes/2026-13-01-diagnostic-x.md",
            "notes/2026-11-06-weird-x.md",
            "notes/2026-11-06-diagnostic-Bad.md",
            "notes/sub/2026-11-06-diagnostic-x.md",
            "docs/specs/Bad_Name.md",
            "docs/adr/1-x.md",
            "docs/deep/x.md",
            "handoffs/a/b.md",
            "docs/index.html"
          ] do
        assert {:refused, _, "foreman doc path " <> _} = DocLayout.classify(path), path
      end
    end

    test "files under a legacy folder are legacy, with the command for a new file" do
      assert {:legacy, "slices/", "foreman doc path brief <ticket-id> --next"} =
               DocLayout.classify("slices/support-board/2b-03-prompt.md", legacy: ["slices/"])

      assert {:legacy, "slices/", "foreman doc path note <kind> overview"} =
               DocLayout.classify("slices/support-board/overview.md", legacy: ["slices"])

      assert {:refused, _, _} = DocLayout.classify("slicesx/a.md", legacy: ["slices"])
    end

    test "a layout path inside a legacy folder stays allowed" do
      assert DocLayout.classify("docs/spec.md", legacy: ["docs"]) == :allowed
    end
  end
end
