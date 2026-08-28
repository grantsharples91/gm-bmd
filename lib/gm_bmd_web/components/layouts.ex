defmodule GmBmdWeb.Layouts do
  @moduledoc false
  use GmBmdWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :identity, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="thor-bridge" phx-hook="ThorBridge" class="min-h-screen bg-base-100 text-base-content">
      <header
        class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-base-300 px-4 py-2"
        data-t3-chrome
      >
        <span class="display-title text-sm">
          GM<span class="text-primary">·</span>BMD
        </span>
        <nav class="flex flex-wrap items-center gap-1 text-[11px] font-bold uppercase tracking-wide">
          <.nav_link navigate={~p"/"} label={gettext("Dashboard")} />
          <.nav_link navigate={~p"/daily"} label={gettext("Daily")} />
          <.nav_link navigate={~p"/outturn"} label={gettext("Outturn")} />
          <.nav_link navigate={~p"/revenue"} label={gettext("Revenue")} />
          <.nav_link navigate={~p"/targets"} label={gettext("Targets")} />
        </nav>
        <span :if={@identity && @identity.email != ""} class="ml-auto text-[11px] text-muted">
          {@identity.email}
        </span>
      </header>
      <main class="mx-auto max-w-[1400px] px-4 py-4">
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="rounded-md px-2 py-1 text-muted hover:bg-base-200 hover:text-base-content"
    >
      {@label}
    </.link>
    """
  end
end
