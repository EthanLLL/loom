defmodule Loom.AuthTest do
  use ExUnit.Case, async: true

  alias Loom.Auth

  test "accepts the configured password and rejects others" do
    assert Auth.valid_password?("test-password")
    refute Auth.valid_password?("wrong")
    refute Auth.valid_password?("")
    refute Auth.valid_password?(nil)
  end

  test "minted tokens verify" do
    token = Auth.mint_token()
    assert :ok = Auth.verify_token(token)
  end

  test "garbage tokens are rejected" do
    assert {:error, _} = Auth.verify_token("not-a-token")
    assert {:error, :missing} = Auth.verify_token(nil)
  end
end
