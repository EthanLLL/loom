defmodule Loom.Agent.DirectoryTest do
  use ExUnit.Case, async: true

  alias Loom.Agent.Directory

  test "a typed path is tidied, and the root is the empty string" do
    assert Directory.normalize(" work / aws/ ") == {:ok, "work/aws"}
    assert Directory.normalize("/a//b/") == {:ok, "a/b"}
    assert Directory.normalize("") == {:ok, ""}
    assert Directory.normalize("/") == {:ok, ""}
    assert Directory.normalize(nil) == {:ok, ""}
    assert Directory.normalize("家/体重") == {:ok, "家/体重"}
  end

  test "dot segments, giant names and non-strings are refused" do
    assert Directory.normalize("a/../b") == {:error, :invalid_directory}
    assert Directory.normalize(String.duplicate("x", 81)) == {:error, :invalid_directory}
    assert Directory.normalize(Enum.join(1..11, "/")) == {:error, :invalid_directory}
    assert Directory.normalize(42) == {:error, :invalid_directory}
  end

  test "rebase swaps the prefix, and only a whole segment counts" do
    assert Directory.rebase("work", "work", "job") == {:ok, "job"}
    assert Directory.rebase("work/aws", "work", "job") == {:ok, "job/aws"}
    assert Directory.rebase("work/aws", "work", "") == {:ok, "aws"}
    assert Directory.rebase("workshop", "work", "job") == :unchanged
    assert Directory.rebase("", "work", "job") == :unchanged
    assert Directory.rebase("anything", "", "job") == :unchanged
  end
end
