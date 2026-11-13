defmodule Loom.Auth do
  @moduledoc """
  Who may use this Loom: one user, signing in on each device with a passkey or
  with the password plus a one-time code.

  Whoever is signed in has a shell, so the door is what is guarded:

  - **Two ways in.** A passkey (`Loom.Auth.WebAuthn`) — Face ID, Touch ID or
    Windows Hello, which is a second factor in itself. Or `LOOM_PASSWORD` with
    a code from an authenticator app (`Loom.Auth.Totp`), or with one of the
    recovery codes made alongside it. Until an authenticator is set up the
    password alone still works, or the first device could never get in to set
    one up; from then on it does not.
  - **One login per device.** A sign-in records a login — the device as its
    user agent names it, how it signed in, its IP — and the token names that
    login. Removing it signs that device out; so does `@idle_days` without
    using it. A device in use never has to sign in again.
  - **Tokens from before logins** (`%{ok: true}`) still work while the
    password alone does, and are swapped for a login of their own the first
    time the app opens (`upgrade/1`), so nobody is signed out by the change.
  - **Failures.** `@max_failures` wrong passwords or codes in
    `@lockout_minutes` lock the password way in for the rest of that window.
    In memory: a restart clears it. Passkeys cannot be guessed and do not count.
  - A new sign-in is announced on every device with notifications on.

  Truth is `~/.loom/auth.json` (mode 0600): passkeys, the authenticator's
  secret, hashed recovery codes, logins. Pending challenges and a secret not
  yet confirmed are only in memory.
  """
  use GenServer

  require Logger

  alias Loom.Auth.{Totp, WebAuthn}

  @name __MODULE__
  @salt "loom auth token"
  # The signature's own limit; a login lapses long before, after @idle_days.
  @max_age 60 * 60 * 24 * 365
  @idle_days 14
  # How stale a login's last_seen_at may get before it is written again.
  @touch_every 3600
  @challenge_ttl 300
  @max_challenges 100
  @max_failures 5
  @lockout_minutes 15
  @recovery_count 8

  def start_link(opts) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def path,
    do:
      Application.get_env(:loom, __MODULE__, [])[:path] ||
        Path.join(Loom.Agent.Store.home(), "auth.json")

  @doc "Verify a plaintext password against the configured one (constant-time)."
  def valid_password?(password) when is_binary(password) do
    configured = Application.get_env(:loom, :password, "")
    configured != "" and Plug.Crypto.secure_compare(password, configured)
  end

  def valid_password?(_), do: false

  @doc """
  The login a token belongs to: `{:ok, id}`, `{:ok, :legacy}` for a token from
  before logins, or `{:error, reason}`. Keeps the login's last_seen_at fresh.
  """
  def verify_token(token, server \\ @name)

  def verify_token(token, server) when is_binary(token) do
    case Phoenix.Token.verify(LoomWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{login: id}} -> GenServer.call(server, {:touch, id})
      {:ok, %{ok: true}} -> GenServer.call(server, :legacy)
      {:ok, _} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_token(_, _), do: {:error, :missing}

  @doc "What the sign-in page offers: `%{passkey: bool, totp: bool}`."
  def options(server \\ @name), do: GenServer.call(server, :options)

  @doc """
  Sign in with the password and, once an authenticator is set up, a code from
  it or a recovery code. `info` is `%{name:, ip:}` for the login.
  `{:ok, token}`, or `{:error, :invalid | :locked}`.
  """
  def password_login(password, code, info, server \\ @name),
    do: GenServer.call(server, {:password_login, password, code, info})

  @doc "A challenge for a passkey to sign, good for #{@challenge_ttl} s, once."
  def challenge(kind, server \\ @name) when kind in [:login, :register],
    do: GenServer.call(server, {:challenge, kind})

  @doc "Sign in with a passkey: the assertion's fields, base64url. `{:ok, token}` or `{:error, _}`."
  def passkey_login(assertion, info, server \\ @name),
    do: GenServer.call(server, {:passkey_login, assertion, info})

  @doc "Keep a new passkey: the registration's fields, base64url, plus `id`."
  def register_passkey(registration, info, server \\ @name),
    do: GenServer.call(server, {:register_passkey, registration, info})

  def delete_passkey(id, server \\ @name), do: GenServer.call(server, {:delete_passkey, id})

  @doc "Start setting up an authenticator: a new secret, kept until confirmed."
  def totp_begin(server \\ @name), do: GenServer.call(server, :totp_begin)

  @doc """
  Confirm the pending secret with a code from the app. From here on the
  password alone is refused. `{:ok, recovery_codes}`, shown once.
  """
  def totp_confirm(code, server \\ @name), do: GenServer.call(server, {:totp_confirm, code})

  def totp_remove(server \\ @name), do: GenServer.call(server, :totp_remove)

  @doc "Swap a token from before logins for one naming a login of its own."
  def upgrade(info, server \\ @name), do: GenServer.call(server, {:upgrade, info})

  @doc "Passkeys, authenticator state and logins, for the settings page."
  def overview(server \\ @name), do: GenServer.call(server, :overview)

  def revoke(id, server \\ @name), do: GenServer.call(server, {:revoke, id})

  @doc "A token for a new login, as a sign-in would make. For tests and tools."
  def mint_token(name \\ "test", server \\ @name),
    do: GenServer.call(server, {:mint, %{name: name, ip: nil}, "password"})

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())

    state =
      path
      |> load()
      |> Map.merge(%{path: path, challenges: %{}, pending_totp: nil, failures: []})

    {:ok, state}
  end

  @impl true
  def handle_call({:touch, id}, _from, state) do
    now = System.os_time(:second)

    case state.logins[id] do
      nil ->
        {:reply, {:error, :revoked}, state}

      login ->
        seen = unix(login.last_seen_at)

        cond do
          now - seen > @idle_days * 86_400 ->
            {:reply, {:error, :expired}, save(%{state | logins: Map.delete(state.logins, id)})}

          now - seen >= @touch_every ->
            state = put_in(state.logins[id].last_seen_at, iso(now))
            {:reply, {:ok, id}, save(state)}

          true ->
            {:reply, {:ok, id}, state}
        end
    end
  end

  def handle_call(:legacy, _from, state) do
    {:reply, if(state.totp, do: {:error, :legacy}, else: {:ok, :legacy}), state}
  end

  def handle_call(:options, _from, state) do
    {:reply, %{passkey: map_size(state.passkeys) > 0, totp: state.totp != nil}, state}
  end

  def handle_call({:password_login, password, code, info}, _from, state) do
    state = prune_failures(state)

    cond do
      length(state.failures) >= @max_failures ->
        {:reply, {:error, :locked}, state}

      not valid_password?(password) ->
        {:reply, {:error, :invalid}, fail(state)}

      state.totp == nil ->
        {token, state} = new_login(state, info, "password")
        {:reply, {:ok, token}, %{state | failures: []}}

      true ->
        case second_factor(state.totp, code) do
          {:ok, totp, method} ->
            {token, state} = new_login(save(%{state | totp: totp}), info, method)
            {:reply, {:ok, token}, %{state | failures: []}}

          :error ->
            {:reply, {:error, :invalid}, fail(state)}
        end
    end
  end

  def handle_call({:challenge, kind}, _from, state) do
    now = System.monotonic_time(:second)
    challenge = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    challenges =
      state.challenges
      |> Map.reject(fn {_, {_, at}} -> now - at > @challenge_ttl end)
      |> Enum.sort_by(fn {_, {_, at}} -> at end, :desc)
      |> Enum.take(@max_challenges - 1)
      |> Map.new()
      |> Map.put(challenge, {kind, now})

    {:reply, challenge, %{state | challenges: challenges}}
  end

  def handle_call({:passkey_login, assertion, info}, _from, state) do
    with id when is_binary(id) <- assertion["id"],
         %{} = passkey <- state.passkeys[id],
         {:ok, challenge} <- WebAuthn.verify(assertion, passkey),
         {:ok, state} <- take_challenge(state, challenge, :login) do
      state = put_in(state.passkeys[id].last_used_at, iso(System.os_time(:second)))
      {token, state} = new_login(state, Map.put(info, :passkey, passkey.name), "passkey")
      {:reply, {:ok, token}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :unknown_passkey}, state}
    end
  end

  def handle_call({:register_passkey, registration, info}, _from, state) do
    with id when is_binary(id) and id != "" <- registration["id"],
         false <- Map.has_key?(state.passkeys, id),
         {:ok, %{challenge: challenge} = checked} <- WebAuthn.register(registration),
         {:ok, state} <- take_challenge(state, challenge, :register) do
      passkey = %{
        id: id,
        name: info.name,
        rp_id: checked.rp_id,
        public_key: checked.public_key,
        created_at: iso(System.os_time(:second)),
        last_used_at: nil
      }

      state = save(put_in(state.passkeys[id], passkey))
      {:reply, {:ok, public_passkey(passkey)}, state}
    else
      true -> {:reply, {:error, :exists}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :malformed}, state}
    end
  end

  def handle_call({:delete_passkey, id}, _from, state) do
    {:reply, :ok, save(%{state | passkeys: Map.delete(state.passkeys, id)})}
  end

  def handle_call(:totp_begin, _from, state) do
    secret = Totp.new_secret()
    {:reply, secret, %{state | pending_totp: secret}}
  end

  def handle_call({:totp_confirm, code}, _from, %{pending_totp: secret} = state)
      when is_binary(secret) do
    case Totp.check(secret, code, nil) do
      {:ok, step} ->
        codes = for _ <- 1..@recovery_count, do: recovery_code()

        totp = %{
          secret: secret,
          last_step: step,
          recovery: Enum.map(codes, &hash_recovery/1),
          created_at: iso(System.os_time(:second))
        }

        {:reply, {:ok, codes}, save(%{state | totp: totp, pending_totp: nil})}

      :error ->
        {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:totp_confirm, _code}, _from, state),
    do: {:reply, {:error, :not_started}, state}

  def handle_call(:totp_remove, _from, state) do
    {:reply, :ok, save(%{state | totp: nil, pending_totp: nil})}
  end

  def handle_call({:upgrade, info}, _from, state) do
    {token, state} = new_login(state, info, "password", announce: false)
    {:reply, {:ok, token}, state}
  end

  def handle_call({:mint, info, method}, _from, state) do
    {token, state} = new_login(state, info, method, announce: false)
    {:reply, token, state}
  end

  def handle_call(:overview, _from, state) do
    overview = %{
      passkeys:
        state.passkeys
        |> Map.values()
        |> Enum.sort_by(& &1.created_at)
        |> Enum.map(&public_passkey/1),
      totp:
        state.totp &&
          %{created_at: state.totp.created_at, recovery_left: length(state.totp.recovery)},
      logins: state.logins |> Map.values() |> Enum.sort_by(& &1.last_seen_at, :desc),
      idle_days: @idle_days
    }

    {:reply, overview, state}
  end

  def handle_call({:revoke, id}, _from, state) do
    {:reply, :ok, save(%{state | logins: Map.delete(state.logins, id)})}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp second_factor(totp, code) do
    case Totp.check(totp.secret, code, totp.last_step) do
      {:ok, step} ->
        {:ok, %{totp | last_step: step}, "password + code"}

      :error ->
        hash = hash_recovery(code)

        if is_binary(code) and hash in totp.recovery,
          do:
            {:ok, %{totp | recovery: List.delete(totp.recovery, hash)},
             "password + recovery code"},
          else: :error
    end
  end

  defp take_challenge(state, challenge, kind) do
    now = System.monotonic_time(:second)

    case Map.pop(state.challenges, challenge) do
      {{^kind, at}, rest} when now - at <= @challenge_ttl -> {:ok, %{state | challenges: rest}}
      _ -> {:error, :challenge}
    end
  end

  defp new_login(state, info, method, opts \\ []) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    now = iso(System.os_time(:second))

    login = %{
      id: id,
      name: info.name,
      method: method_label(method, info),
      ip: info.ip,
      created_at: now,
      last_seen_at: now
    }

    if Keyword.get(opts, :announce, true) do
      Loom.Push.announce(
        "New sign-in to Loom",
        "#{login.name}, #{login.method}" <> ip_note(info.ip)
      )
    end

    state = save(put_in(state.logins[id], login))
    {Phoenix.Token.sign(LoomWeb.Endpoint, @salt, %{login: id}), state}
  end

  # A passkey made elsewhere — a PC signing in with the phone next to it — says where.
  defp method_label("passkey", %{passkey: made_on, name: name}) when made_on != name,
    do: "passkey made on #{made_on}"

  defp method_label(method, _info), do: method

  defp ip_note(nil), do: ""
  defp ip_note(ip), do: ", from #{ip}"

  defp fail(state), do: %{state | failures: [System.monotonic_time(:second) | state.failures]}

  defp prune_failures(state) do
    now = System.monotonic_time(:second)
    %{state | failures: Enum.filter(state.failures, &(now - &1 < @lockout_minutes * 60))}
  end

  # Ten base32 characters in two groups of five, to be typed from paper.
  # Compared ignoring case and dashes.
  defp recovery_code do
    <<a::binary-5, b::binary-5>> =
      :crypto.strong_rand_bytes(10) |> Base.encode32(case: :lower) |> binary_part(0, 10)

    a <> "-" <> b
  end

  defp hash_recovery(code) when is_binary(code) do
    normalized = code |> String.downcase() |> String.replace(~r/[^a-z2-7]/, "")
    :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
  end

  defp hash_recovery(_), do: nil

  defp public_passkey(p), do: Map.take(p, [:id, :name, :rp_id, :created_at, :last_used_at])

  defp unix(iso) do
    case DateTime.from_iso8601(iso || "") do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp iso(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  # ── Storage ─────────────────────────────────────────────────────────────

  @passkey_keys ~w(id name rp_id public_key created_at last_used_at)a
  @login_keys ~w(id name method ip created_at last_seen_at)a

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = data} <- Jason.decode(body) do
      %{
        passkeys: index(data["passkeys"], @passkey_keys),
        logins: index(data["logins"], @login_keys),
        totp:
          case data["totp"] do
            %{"secret" => secret} = t when is_binary(secret) ->
              %{
                secret: secret,
                last_step: t["last_step"],
                recovery: t["recovery"] || [],
                created_at: t["created_at"]
              }

            _ ->
              nil
          end
      }
    else
      {:error, :enoent} ->
        %{passkeys: %{}, logins: %{}, totp: nil}

      _ ->
        # Not overwritten: it may hold the only way in other than the password.
        # The password alone works until it is fixed, as before any setup.
        aside = "#{path}.bad-#{System.os_time(:second)}"
        File.rename(path, aside)
        Logger.error("Loom.Auth cannot read #{path}; moved it to #{aside}")
        %{passkeys: %{}, logins: %{}, totp: nil}
    end
  end

  defp index(list, keys) when is_list(list) do
    for item <- list, is_binary(item["id"]), into: %{} do
      {item["id"], Map.new(keys, &{&1, item[to_string(&1)]})}
    end
  end

  defp index(_, _), do: %{}

  defp save(state) do
    body = %{
      passkeys: state.passkeys |> Map.values() |> Enum.sort_by(& &1.created_at),
      totp: state.totp,
      logins: state.logins |> Map.values() |> Enum.sort_by(& &1.created_at)
    }

    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(body, pretty: true))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, state.path)
    state
  end
end
