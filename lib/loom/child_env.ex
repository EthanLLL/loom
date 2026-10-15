defmodule Loom.ChildEnv do
  @moduledoc """
  The environment loom hands to everything it spawns: agent CLIs and terminal
  shells.

  Loom's own environment is not fit to pass on. `rel/env.sh.eex` sources `.env`
  with auto-export, so the node carries `LOOM_PASSWORD` and `SECRET_KEY_BASE` —
  and every agent and shell would inherit them. It also carries `PHX_SERVER=true`,
  which makes a `mix test` run inside a loom terminal try to bind :4000 and fail
  against the very server it is running under. And the release script puts its
  own `erts-*/bin` and `bin` at the front of `PATH`, so a child running `erl`
  gets the release's runtime rather than the user's install.

  So: loom's own variables are dropped, the release's directories are taken off
  `PATH`, and everything else passes through untouched.
  """

  # Read by loom itself (config/runtime.exs and the release scripts); nothing a
  # child process needs.
  @loom_vars ~w(
    SECRET_KEY_BASE LOOM_PASSWORD PHX_SERVER PHX_HOST PORT
    LOOM_BIND LOOM_HOME LOOM_CLAUDE_CLI LOOM_CODEX_CLI LOOM_WORKSPACE
    BINDIR ROOTDIR EMU PROGNAME
  )

  @doc "The child environment as a map, for APIs that take a whole environment."
  def map(env \\ System.get_env()) do
    root = env["RELEASE_ROOT"]

    env
    |> Map.reject(fn {name, _} -> loom_var?(name) end)
    |> clean_path(root)
  end

  @doc """
  The same environment as a `Port.open/2` `:env` option.

  A port only *adds* to the parent's environment, so dropped variables have to
  be unset explicitly (`false`) rather than just left out.
  """
  def port_env(env \\ System.get_env()) do
    kept = map(env)

    unset =
      for {name, _} <- env, not Map.has_key?(kept, name) do
        {String.to_charlist(name), false}
      end

    set = for {name, value} <- kept, do: {String.to_charlist(name), String.to_charlist(value)}

    unset ++ set
  end

  defp loom_var?(name), do: name in @loom_vars or String.starts_with?(name, "RELEASE_")

  defp clean_path(env, nil), do: env

  defp clean_path(%{"PATH" => path} = env, root) do
    prefix = String.trim_trailing(root, "/") <> "/"

    cleaned =
      path
      |> String.split(":")
      |> Enum.reject(&String.starts_with?(&1 <> "/", prefix))
      |> Enum.join(":")

    Map.put(env, "PATH", cleaned)
  end

  defp clean_path(env, _root), do: env
end
