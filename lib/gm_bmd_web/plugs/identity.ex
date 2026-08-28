defmodule GmBmdWeb.Identity do
  @moduledoc """
  THOR3 identity. Auth lives at the ingress — every request already passed
  THOR3 login, and identity arrives as trusted `x-thor-*` headers. This module
  reads them into an identity map; it never checks passwords and never renders
  a login page. In dev/test the configured `:dev_identity` stub injects the
  same headers so the exact code path runs everywhere.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    identity = read_identity(conn)

    conn
    |> assign(:identity, identity)
    |> put_session(:identity, identity)
  end

  @doc "Build the identity map from headers (with the dev stub as fallback)."
  def read_identity(conn) do
    stub = Application.get_env(:gm_bmd, :dev_identity, %{})
    header = fn name -> first_header(conn, name) || Map.get(stub, name, "") end

    %{
      user_id: header.("x-thor-user-id"),
      email: header.("x-thor-email"),
      groups: split(header.("x-thor-groups")),
      clubs: split(header.("x-thor-clubs")),
      perms: split(header.("x-thor-perms")),
      locale: normalize_locale(header.("x-thor-locale")),
      theme: header.("x-thor-theme")
    }
  end

  @doc "Fallback identity when the session cookie is unavailable (WebKit ITP)."
  def anonymous do
    %{user_id: "", email: "", groups: [], clubs: [], perms: [], locale: "en", theme: "system"}
  end

  @doc "Display name for approvals/forecast stamps — email local part."
  def display_name(%{email: email}) when is_binary(email) and email != "" do
    email |> String.split("@") |> hd()
  end

  def display_name(_identity), do: "manager"

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp split(""), do: []
  defp split(nil), do: []
  defp split(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp normalize_locale("ar"), do: "ar"
  defp normalize_locale(_), do: "en"
end
