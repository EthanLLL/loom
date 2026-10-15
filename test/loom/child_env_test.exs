defmodule Loom.ChildEnvTest do
  use ExUnit.Case, async: true

  alias Loom.ChildEnv

  @parent %{
    "HOME" => "/home/u",
    "LANG" => "C.UTF-8",
    "LOOM_PASSWORD" => "secret",
    "SECRET_KEY_BASE" => "kb",
    "PHX_SERVER" => "true",
    "RELEASE_ROOT" => "/srv/rel/loom",
    "RELEASE_COOKIE" => "cookie",
    "PATH" => "/srv/rel/loom/erts-16.3/bin:/srv/rel/loom/bin:/home/u/.local/bin:/usr/bin"
  }

  test "loom's own variables do not reach children" do
    env = ChildEnv.map(@parent)

    for name <- ~w(LOOM_PASSWORD SECRET_KEY_BASE PHX_SERVER RELEASE_ROOT RELEASE_COOKIE) do
      refute Map.has_key?(env, name), "#{name} leaked"
    end

    assert env["HOME"] == "/home/u"
    assert env["LANG"] == "C.UTF-8"
  end

  test "the release's directories come off PATH, the rest stays in order" do
    assert ChildEnv.map(@parent)["PATH"] == "/home/u/.local/bin:/usr/bin"
  end

  test "outside a release PATH is left alone" do
    env = Map.delete(@parent, "RELEASE_ROOT")
    assert ChildEnv.map(env)["PATH"] == @parent["PATH"]
  end

  test "the port form unsets what it drops" do
    env = ChildEnv.port_env(@parent)

    assert {~c"LOOM_PASSWORD", false} in env
    assert {~c"HOME", ~c"/home/u"} in env
  end
end
