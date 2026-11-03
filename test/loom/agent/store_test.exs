defmodule Loom.Agent.StoreTest do
  @moduledoc """
  The one-time move of session data out of the release and into `~/.loom`.

  It runs at boot, copies files, and nothing else would notice if it quietly
  did the wrong thing — so the two properties that keep it safe are pinned here:
  it never overwrites, and it is idempotent at file granularity.
  """
  use ExUnit.Case, async: false

  alias Loom.Agent.Store

  setup do
    unique = System.unique_integer([:positive])
    data_dir = Path.join(System.tmp_dir!(), "loom-store-#{unique}")
    legacy = Path.join(System.tmp_dir!(), "loom-store-legacy-#{unique}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous |> Keyword.put(:data_dir, data_dir) |> Keyword.put(:legacy_dir, legacy)
    )

    id = "a_legacy_#{unique}"
    from = Path.join(legacy, id)
    File.mkdir_p!(from)

    on_exit(fn ->
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(legacy)
      File.rm_rf(data_dir)
    end)

    {:ok, id: id, from: from}
  end

  test "copies a legacy session and leaves the original alone", %{id: id, from: from} do
    File.write!(Path.join(from, "meta.json"), ~s({"id":"#{id}"}))
    File.write!(Path.join(from, "events.jsonl"), ~s({"seq":1}\n))

    assert Store.migrate_legacy() == :ok

    assert File.read!(Path.join(Store.session_dir(id), "events.jsonl")) =~ ~s("seq":1)
    assert {:ok, %{id: ^id}} = Store.read_meta(id)
    # Copy, not move: a mistake here should be annoying, not unrecoverable.
    assert File.exists?(Path.join(from, "meta.json"))
  end

  test "a directory with no header is not a session", %{from: from} do
    File.write!(Path.join(from, "stray.txt"), "junk")
    assert Store.migrate_legacy() == :ok
    refute File.exists?(Store.data_dir())
  end

  test "never overwrites what is already in the new location", %{id: id, from: from} do
    File.write!(Path.join(from, "meta.json"), ~s({"id":"#{id}","title":"old"}))
    File.mkdir_p!(Store.session_dir(id))
    File.write!(Path.join(Store.session_dir(id), "meta.json"), ~s({"id":"#{id}","title":"new"}))

    assert Store.migrate_legacy() == :ok

    assert {:ok, %{title: "new"}} = Store.read_meta(id)
  end

  test "fills in what a half-finished move left behind", %{id: id, from: from} do
    # Exactly what a hot-reloaded path change produces: the header is written to
    # the new location while the open transcript keeps appending to the old one.
    File.write!(Path.join(from, "meta.json"), ~s({"id":"#{id}"}))
    File.write!(Path.join(from, "events.jsonl"), ~s({"seq":1}\n))
    File.mkdir_p!(Store.session_dir(id))
    File.write!(Path.join(Store.session_dir(id), "meta.json"), ~s({"id":"#{id}"}))

    assert Store.migrate_legacy() == :ok

    assert File.exists?(Path.join(Store.session_dir(id), "events.jsonl"))
  end

  test "running it twice changes nothing", %{id: id, from: from} do
    File.write!(Path.join(from, "meta.json"), ~s({"id":"#{id}"}))
    assert Store.migrate_legacy() == :ok

    stat = File.stat!(Path.join(Store.session_dir(id), "meta.json"))
    assert Store.migrate_legacy() == :ok
    assert File.stat!(Path.join(Store.session_dir(id), "meta.json")).mtime == stat.mtime
  end

  describe "delete_session/1" do
    test "moves the session into the trash rather than removing it" do
      id = "a_gone"
      Store.write_meta(id, %{id: id, title: "t"})
      File.write!(Path.join(Store.session_dir(id), "events.jsonl"), ~s({"seq":1}\n))

      assert Store.delete_session(id) == :ok

      refute File.exists?(Store.session_dir(id))
      assert [kept] = File.ls!(Store.trash_dir())
      assert kept =~ ~r/^a_gone\.\d+$/
      assert File.read!(Path.join([Store.trash_dir(), kept, "events.jsonl"])) =~ ~s("seq":1)
      # The trash is not a session.
      assert Store.list_metas() == []
    end

    test "refuses an id that would name the data directory or step out of it" do
      Store.write_meta("a_kept", %{id: "a_kept"})

      for id <- ["", ".", "..", ".trash", "../x", "a/b", "/"] do
        assert Store.delete_session(id) == {:error, :invalid_id}
      end

      assert {:ok, _} = Store.read_meta("a_kept")
    end

    test "an id with nothing on disk is fine" do
      assert Store.delete_session("a_never") == :ok
    end
  end
end
