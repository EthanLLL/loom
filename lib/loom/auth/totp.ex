defmodule Loom.Auth.Totp do
  @moduledoc """
  Time-based one-time codes (RFC 6238): HMAC-SHA1, 30-second steps, six
  digits — the defaults every authenticator app assumes when the `otpauth://`
  URI names nothing else.
  """
  import Bitwise

  @period 30

  @doc "A new secret: 20 random bytes, base32 without padding, as apps expect."
  def new_secret, do: Base.encode32(:crypto.strong_rand_bytes(20), padding: false)

  @doc "The current time step."
  def step(now \\ System.os_time(:second)), do: div(now, @period)

  @doc """
  The step `code` is valid for, allowing one step of clock drift either way,
  and only if it is later than `last_step`: a code is good once.
  """
  def check(secret, code, last_step, now \\ System.os_time(:second)) do
    code = normalize(code)

    with {:ok, key} <- Base.decode32(secret, padding: false),
         true <- String.match?(code, ~r/^\d{6}$/) do
      current = step(now)

      Enum.find_value([current - 1, current, current + 1], :error, fn s ->
        if s > (last_step || 0) and Plug.Crypto.secure_compare(code(key, s), code),
          do: {:ok, s}
      end)
    else
      _ -> :error
    end
  end

  @doc "The code for `step`, given the raw key."
  def code(key, step) do
    mac = :crypto.mac(:hmac, :sha, key, <<step::64>>)
    offset = :binary.at(mac, 19) &&& 0x0F
    <<_::binary-size(^offset), value::32, _::binary>> = mac
    (value &&& 0x7FFFFFFF) |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  defp normalize(code) when is_binary(code), do: String.replace(code, ~r/\s/, "")
  defp normalize(_), do: ""
end
