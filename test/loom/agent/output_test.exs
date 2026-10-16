defmodule Loom.Agent.OutputTest do
  @moduledoc """
  Which files count as the user's downloads, and which paths a download may
  name. The second half is the one that matters: the path comes from a URL.
  """
  use ExUnit.Case, async: false

  alias Loom.Agent.Output
  alias Loom.Agent.Store

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-out-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(previous, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    id = "a_out"
    Output.ensure_dir(id)
    {:ok, id: id, dir: Store.output_dir(id), data_dir: data_dir}
  end

  defp put(dir, rel, content \\ "x") do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "snapshot/1 and changes/2" do
    test "lists regular files by relative path, nested ones included", %{id: id, dir: dir} do
      put(dir, "a.txt", "abc")
      put(dir, "deck/slides.pptx")
      File.mkdir_p!(Path.join(dir, "empty"))

      assert %{"a.txt" => {3, _}, "deck/slides.pptx" => {1, _}} = snap = Output.snapshot(id)
      assert map_size(snap) == 2
    end

    test "skips hidden files, Office lock files and symlinks", %{id: id, dir: dir} do
      put(dir, ".env", "secret")
      put(dir, ".cache/x.bin")
      put(dir, "~$report.xlsx")
      File.ln_s!("/etc/hostname", Path.join(dir, "link.txt"))

      assert Output.snapshot(id) == %{}
    end

    test "reports new and changed files, not unchanged or deleted ones" do
      before = %{"same" => {1, 10}, "changed" => {1, 10}, "gone" => {1, 10}}
      now = %{"same" => {1, 10}, "changed" => {2, 11}, "new.csv" => {5, 12}}

      assert %{files: [changed, new], more: 0, open: nil} = Output.changes(before, now)
      assert %{kind: "file", path: "changed", updated: true, size: 2} = changed
      assert %{path: "new.csv", name: "new.csv", updated: false, content_type: "text/csv"} = new
    end

    test "a directory is one entry, however many files changed in it" do
      now =
        Map.new(1..40, &{"manga-ch12/images/#{&1}.jpg", {100, 5}})
        |> Map.put("manga-ch12/index.html", {50, 6})
        |> Map.put("data/raw.csv", {7, 5})

      assert %{files: [data, manga], more: 0} = Output.changes(%{}, now)
      assert %{kind: "dir", path: "data", files: 1, index: nil} = data

      assert %{kind: "dir", path: "manga-ch12", files: 41, size: 4050, updated: false} = manga
      assert manga.index == "manga-ch12/index.html"
    end

    test "a directory is updated when it existed before; a page in it opens again" do
      before = %{"site/index.html" => {1, 1}, "site/a.png" => {1, 1}}
      now = %{"site/index.html" => {1, 1}, "site/a.png" => {2, 2}}

      assert %{files: [%{kind: "dir", updated: true}], open: "site/index.html"} =
               Output.changes(before, now)
    end

    test "the newest index.html opens; nothing else ever does" do
      now = %{
        "old/index.html" => {1, 10},
        "new/index.html" => {1, 20},
        "index.html" => {1, 15},
        "deep/a/index.html" => {1, 30},
        "photo.png" => {1, 40}
      }

      assert %{open: "new/index.html"} = Output.changes(%{}, now)
      assert %{open: nil} = Output.changes(%{}, %{"photo.png" => {1, 1}, "x/a.html" => {1, 1}})
      assert %{open: "index.html"} = Output.changes(%{}, %{"index.html" => {1, 1}})
    end

    test "a flood of entries is cut short and says by how much" do
      now = Map.new(1..60, &{"f#{&1}", {1, 1}})
      assert %{files: files, more: 10} = Output.changes(%{}, now)
      assert length(files) == 50
    end
  end

  describe "resolve_dir/2 and files_under/2" do
    test "a directory inside is accepted and lists what a zip may hold", %{id: id, dir: dir} do
      put(dir, "site/index.html")
      put(dir, "site/img/a.png", "png")
      put(dir, "site/.secret")
      File.ln_s!("/etc/hostname", Path.join(dir, "site/link.txt"))

      assert {:ok, _} = Output.resolve_dir(id, "site")
      assert Output.files_under(id, "site") == [{"site/img/a.png", 3}, {"site/index.html", 1}]
    end

    test "climbing out, hidden and missing directories are refused", %{id: id, dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      File.ln_s!("/etc", Path.join(dir, "etc"))

      for rel <- ["..", ".", ".git", "etc", "missing", "/tmp"] do
        assert Output.resolve_dir(id, rel) == :error, rel
      end
    end
  end

  describe "resolve/2" do
    test "accepts a file inside the directory", %{id: id, dir: dir} do
      path = put(dir, "deck/slides.pptx")
      assert Output.resolve(id, "deck/slides.pptx") == {:ok, path}
    end

    test "refuses anything that climbs out", %{id: id, data_dir: data_dir} do
      put(Path.join(data_dir, "a_out"), "meta.json", "{}")

      assert Output.resolve(id, "../meta.json") == :error
      assert Output.resolve(id, "deck/../../meta.json") == :error
      assert Output.resolve(id, "/etc/passwd") == :error
    end

    test "refuses symlinks, even ones inside the directory", %{id: id, dir: dir} do
      File.ln_s!("/etc/hostname", Path.join(dir, "out.txt"))
      put(dir, "real/file.txt")
      File.ln_s!(Path.join(dir, "real"), Path.join(dir, "alias"))

      assert Output.resolve(id, "out.txt") == :error
      assert Output.resolve(id, "alias/file.txt") == :error
    end

    test "refuses hidden files, directories and what is not there", %{id: id, dir: dir} do
      put(dir, ".env")
      File.mkdir_p!(Path.join(dir, "sub"))

      assert Output.resolve(id, ".env") == :error
      assert Output.resolve(id, "sub") == :error
      assert Output.resolve(id, ".") == :error
      assert Output.resolve(id, "missing.txt") == :error
    end
  end

  test "the instructions name the directory, the link form and the canvas", %{id: id, dir: dir} do
    text = Output.instructions(id)
    assert text =~ dir
    assert text =~ "(output/"
    assert text =~ "#{dir}/<name>/index.html"
  end
end
