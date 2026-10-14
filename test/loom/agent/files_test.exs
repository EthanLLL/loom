defmodule Loom.Agent.FilesTest do
  @moduledoc """
  Attachments on disk.

  Two things here are worth pinning down. The filename comes from a client and
  is therefore a hostile string, and the path a client sends back on submit is a
  capability — the model reads whatever we name it.
  """
  use ExUnit.Case, async: false

  alias Loom.Agent.Files
  alias Loom.Agent.Store

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-files-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(previous, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    {:ok, session: "a_files", data_dir: data_dir}
  end

  defp upload(filename, content \\ "hello") do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %{filename: filename, path: path}
  end

  describe "store/2" do
    test "writes the file under the session and reports where", %{session: id} do
      assert {:ok, file} = Files.store(id, upload("notes.md", "# hi"))

      assert file.name == "notes.md"
      assert file.path == Path.join(Store.files_dir(id), "notes.md")
      assert file.size == 4
      assert file.content_type == "text/markdown"
      assert File.read!(file.path) == "# hi"
    end

    test "a traversing filename cannot escape the session directory", %{session: id} do
      assert {:ok, file} = Files.store(id, upload("../../../.ssh/authorized_keys"))

      assert Path.dirname(file.path) == Store.files_dir(id)
      refute file.name =~ "/"
    end

    test "separators, control characters and a Windows path are neutralised", %{session: id} do
      assert {:ok, file} = Files.store(id, upload("C:\\evil\t/name?.txt"))
      assert Path.dirname(file.path) == Store.files_dir(id)
      refute file.name =~ ~r"[\\/?\t]"
    end

    test "a name of nothing but dots still produces a file", %{session: id} do
      assert {:ok, file} = Files.store(id, upload(".."))
      assert file.name == "file"
    end

    test "CJK names are kept as they are", %{session: id} do
      # The author's filenames are full of them, and mangling into
      # `____.png` would make the tray unreadable.
      assert {:ok, file} = Files.store(id, upload("截图 2026.png"))
      assert file.name == "截图 2026.png"
    end

    test "the second file of the same name does not overwrite the first", %{session: id} do
      assert {:ok, first} = Files.store(id, upload("shot.png", "one"))
      assert {:ok, second} = Files.store(id, upload("shot.png", "two"))

      assert second.name == "shot-1.png"
      assert File.read!(first.path) == "one"
      assert File.read!(second.path) == "two"
    end

    test "an absurd name is truncated but keeps its extension", %{session: id} do
      assert {:ok, file} = Files.store(id, upload(String.duplicate("a", 400) <> ".png"))
      assert String.length(file.name) <= 100
      assert Path.extname(file.name) == ".png"
    end

    test "an empty file is refused", %{session: id} do
      assert {:error, :empty} = Files.store(id, upload("nothing.txt", ""))
    end

    test "an oversized file is refused", %{session: id} do
      big = String.duplicate("x", 26 * 1024 * 1024)
      assert {:error, :too_large} = Files.store(id, upload("big.bin", big))
    end
  end

  describe "verify/2" do
    test "accepts a path this session stored", %{session: id} do
      {:ok, stored} = Files.store(id, upload("a.txt"))

      assert {:ok, [file]} = Files.verify(id, [stored.path])
      assert file.name == "a.txt"
      assert file.size == 5
    end

    test "refuses a path outside the session's own directory", %{session: id} do
      # The client supplies this path and the model reads whatever we name, so
      # a rewritten field must not turn into a read of an arbitrary file.
      assert {:error, {:not_an_attachment, "/etc/passwd"}} = Files.verify(id, ["/etc/passwd"])

      escape = Path.join(Store.files_dir(id), "../../../../etc/passwd")
      assert {:error, {:not_an_attachment, _}} = Files.verify(id, [escape])
    end

    test "refuses another session's attachment", %{session: id} do
      {:ok, theirs} = Files.store("a_other", upload("secret.txt"))
      assert {:error, {:not_an_attachment, _}} = Files.verify(id, [theirs.path])
    end

    test "refuses a path that is not there", %{session: id} do
      gone = Path.join(Store.files_dir(id), "gone.txt")
      assert {:error, {:not_an_attachment, ^gone}} = Files.verify(id, [gone])
    end

    test "no attachments is not an error", %{session: id} do
      assert {:ok, []} = Files.verify(id, [])
    end
  end

  describe "prompt/2" do
    test "is the message unchanged when nothing is attached" do
      assert Files.prompt("hello", []) == "hello"
    end

    test "names the paths and says they are local files to read" do
      files = [%{name: "a.png", path: "/x/a.png"}, %{name: "b.csv", path: "/x/b.csv"}]
      prompt = Files.prompt("what is this", files)

      assert prompt =~ "what is this"
      assert prompt =~ "/x/a.png"
      assert prompt =~ "/x/b.csv"
      assert prompt =~ "read them"
    end

    test "works with no words typed at all" do
      prompt = Files.prompt("  ", [%{name: "a.png", path: "/x/a.png"}])
      assert String.starts_with?(prompt, "Attached 1 file")
      assert prompt =~ "read it"
    end
  end
end
