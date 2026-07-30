defmodule Loom.Terminal.SgrTest do
  use ExUnit.Case, async: true

  alias Loom.Terminal.Sgr

  test "rewrites colon-form truecolor foreground to semicolon form" do
    assert Sgr.transform("\e[38:2:130:139:184mhi") == "\e[38;2;130;139;184mhi"
  end

  test "rewrites background truecolor too" do
    assert Sgr.transform("\e[48:2:1:2:3mX") == "\e[48;2;1;2;3mX"
  end

  test "leaves semicolon-form truecolor untouched" do
    assert Sgr.transform("\e[38;2;10;20;30mok") == "\e[38;2;10;20;30mok"
  end

  test "leaves 256-color and plain text untouched" do
    assert Sgr.transform("\e[38;5;42m plain \e[0m text") ==
             "\e[38;5;42m plain \e[0m text"
  end

  test "handles truecolor combined with other params in one CSI" do
    assert Sgr.transform("\e[1;38:2:200:100:50;4mbold") ==
             "\e[1;38;2;200;100;50;4mbold"
  end

  test "passes control sequences through untouched (stateless, no buffering)" do
    # These are exactly the sequences whose delayed delivery used to break
    # TUI redraws: cursor save/restore, clear line, OSC, charset, etc.
    for seq <- ["\e7", "\e8", "\e[K", "\e]0;title\a", "\e(B", "\e=", "\e[0m"] do
      assert Sgr.transform("text" <> seq) == "text" <> seq
    end
  end

  test "a trailing bare ESC is forwarded, not held back" do
    # No carry: whatever arrives is emitted as-is (rewrites don't cross reads).
    assert Sgr.transform("some content\e") == "some content\e"
  end
end
