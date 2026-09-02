defmodule GmBmdWeb.Layouts do
  @moduledoc false
  use GmBmdWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :identity, :map, default: nil
  attr :current_path, :string, default: "/"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="thor-bridge" phx-hook="ThorBridge" class="min-h-screen bg-base-100 text-base-content">
      <header
        class="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-base-300 px-4 py-2"
        data-t3-chrome
      >
        <span class="display-title text-sm">
          General Manager <span class="text-primary">-</span> Business Management Dashboard
        </span>
        <nav class="flex flex-wrap items-center gap-1 text-[11px] font-bold uppercase tracking-wide">
          <.nav_link navigate={~p"/"} label={gettext("Dashboard")} current_path={@current_path} />
          <.nav_link navigate={~p"/daily"} label={gettext("Daily")} current_path={@current_path} />
          <.nav_link navigate={~p"/outturn"} label={gettext("Outturn")} current_path={@current_path} />
          <.nav_link navigate={~p"/revenue"} label={gettext("Revenue")} current_path={@current_path} />
          <.nav_link navigate={~p"/targets"} label={gettext("Targets")} current_path={@current_path} />
        </nav>
        <span class="ms-auto flex items-center gap-3">
          <.feed_badge />
          <span
            id="theme-toggle"
            phx-hook="ThemeToggle"
            phx-update="ignore"
            class="t3-hide-framed flex h-7 items-stretch overflow-hidden rounded-md border border-base-300 bg-base-100 text-[10px] font-bold uppercase tracking-wide"
            role="group"
            aria-label={gettext("Theme")}
          >
            <button type="button" data-theme-choice="light" class="px-2 text-muted hover:bg-base-200">
              {gettext("Light")}
            </button>
            <button type="button" data-theme-choice="dark" class="px-2 text-muted hover:bg-base-200">
              {gettext("Dark")}
            </button>
            <button type="button" data-theme-choice="auto" class="px-2 text-muted hover:bg-base-200">
              {gettext("Auto")}
            </button>
          </span>
          <span :if={@identity && @identity.email != ""} class="text-[11px] text-muted">
            {@identity.email}
          </span>
        </span>
      </header>
      <main class="mx-auto max-w-[1400px] px-4 py-4">
        <.flash_group flash={@flash} />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  # Where the numbers come from: the THOR feed's as-of date, or the seeded
  # placeholder set when no feed has been loaded yet.
  defp feed_badge(assigns) do
    assigns = assign(assigns, :feed, feed_info())

    ~H"""
    <span
      class="hidden items-center gap-1.5 rounded-md border border-base-300 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide text-muted sm:inline-flex"
      title={@feed.title}
    >
      <span class={["size-1.5 rounded-full", @feed.live? && "bg-positive", !@feed.live? && "bg-base-300"]}>
      </span>
      {@feed.label}
    </span>
    """
  end

  defp feed_info do
    case GmBmd.Bridge.as_of() do
      %Date{} = as_of ->
        %{
          live?: true,
          label: "THOR · data to #{Calendar.strftime(as_of, "%-d %b")}",
          title: "Figures from the THOR Executive Forecast feed (Telr), complete to #{Calendar.strftime(as_of, "%-d %B %Y")}. Mapping is provisional."
        }

      nil ->
        %{live?: false, label: "Placeholder data", title: "Seeded placeholder figures — no feed loaded."}
    end
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :current_path, :string, default: "/"

  defp nav_link(assigns) do
    assigns = assign(assigns, :active?, assigns.current_path == assigns.navigate)

    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active? && "page"}
      class={[
        "rounded-md px-2.5 py-1.5 transition-colors",
        @active? && "bg-primary text-primary-content shadow-sm",
        !@active? && "text-muted hover:bg-base-200 hover:text-base-content"
      ]}
    >
      {@label}
    </.link>
    """
  end
end
