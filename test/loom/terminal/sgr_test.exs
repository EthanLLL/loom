defmodule Loom.Terminal.SgrTest do
  use ExUnit.Case, async: true

  alias Loom.Terminal.Sgr

  test "rewrites colon-form truecolor foreground to semicolon form" do
    {out, carry} = Sgr.transform("\e[38:2:130:139:184mhi")
    assert out == "\e[38;2;130;139;184mhi"
    assert carry == ""
  end

  test "rewrites background truecolor too" do
    {out, _} = Sgr.transform("\e[48:2:1:2:3mX")
    assert out == "\e[48;2;1;2;3mX"
  end

  test "leaves semicolon-form truecolor untouched" do
    {out, _} = Sgr.transform("\e[38;2;10;20;30mok")
    assert out == "\e[38;2;10;20;30mok"
  end

  test "leaves 256-color and plain text untouched" do
    {out, _} = Sgr.transform("\e[38;5;42m plain \e[0m text")
    assert out == "\e[38;5;42m plain \e[0m text"
  end

  test "handles truecolor combined with other params in one CSI" do
    {out, _} = Sgr.transform("\e[1;38:2:200:100:50;4mbold")
    assert out == "\e[1;38;2;200;100;50;4mbold"
  end

  test "holds back a sequence split across two reads and rewrites once complete" do
    # First read ends mid-escape-sequence.
    {out1, carry1} = Sgr.transform("text\e[38:2:130:139")
    assert out1 == "text"
    assert carry1 == "\e[38:2:130:139"

    # Second read completes it.
    {out2, carry2} = Sgr.transform(":184mrest", carry1)
    assert out2 == "\e[38;2;130;139;184mrest"
    assert carry2 == ""
  end

  test "does not hold back a completed sequence" do
    {out, carry} = Sgr.transform("\e[0m")
    assert out == "\e[0m"
    assert carry == ""
  end
end
