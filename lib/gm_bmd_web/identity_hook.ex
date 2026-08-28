defmodule GmBmdWeb.IdentityHook do
  @moduledoc """
  Puts the THOR3 identity into every LiveView's assigns from the session.

  WebKit's ITP can drop the third-party cookie entirely, so the socket may
  connect with an EMPTY session even though the first HTTP render worked —
  always fall back to an anonymous identity rather than crashing the connect
  (the request still passed THOR3 login at the ingress).
  """

  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    identity =
      case session do
        %{"identity" => %{} = identity} -> atomize(identity)
        _ -> GmBmdWeb.Identity.anonymous()
      end

    {:cont, assign(socket, identity: identity)}
  end

  # Session round-trips may stringify keys; accept both shapes.
  defp atomize(%{user_id: _} = identity), do: identity

  defp atomize(map) do
    %{
      user_id: Map.get(map, "user_id", ""),
      email: Map.get(map, "email", ""),
      groups: Map.get(map, "groups", []),
      clubs: Map.get(map, "clubs", []),
      perms: Map.get(map, "perms", []),
      locale: Map.get(map, "locale", "en"),
      theme: Map.get(map, "theme", "system")
    }
  end
end
