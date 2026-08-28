defmodule GmBmdWeb.CoreComponents do
  @moduledoc """
  Shared UI primitives: flash, icons (inline SVG — no icon dependency),
  popovers (`<details>`-based, no JS) and small formatting helpers.
  """
  use Phoenix.Component
  use Gettext, backend: GmBmdWeb.Gettext

  alias GmBmd.Format

  # ------------------------------------------------------------------- flash

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], required: true

  def flash(assigns) do
    msg = Phoenix.Flash.get(assigns.flash, assigns.kind)
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <p
      :if={@msg}
      class={[
        "mb-3 rounded-md px-3 py-2 text-xs font-semibold ring-1",
        @kind == :info && "bg-positive-soft text-positive ring-positive/40",
        @kind == :error && "bg-negative-soft text-negative ring-negative/40"
      ]}
      phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: @kind})}
    >
      {@msg}
    </p>
    """
  end

  # ------------------------------------------------------------------- icons

  @icon_paths %{
    "info" => "M12 16v-4m0-4h.01M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z",
    "lock" => "M7 11V7a5 5 0 0 1 10 0v4M5 11h14v10H5V11Z",
    "unlock" => "M7 11V7a5 5 0 0 1 9.9-1M5 11h14v10H5V11Z",
    "arrow-left" => "M19 12H5m0 0 7 7m-7-7 7-7",
    "check" => "M20 6 9 17l-5-5",
    "copy" => "M8 8h12v12H8V8Zm-4 8V4h12",
    "printer" => "M6 9V3h12v6M6 18h12v3H6v-3Zm-3-9h18v9h-3M6 14h12",
    "download" => "M12 3v12m0 0 4-4m-4 4-4-4M4 21h16",
    "alert" => "M12 9v4m0 4h.01M10.3 3.8 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.8a2 2 0 0 0-3.4 0Z",
    "trending-up" => "m3 17 6-6 4 4 8-8m0 0h-5m5 0v5",
    "history" => "M3 12a9 9 0 1 0 3-6.7M3 4v5h5M12 7v5l3 3",
    "calendar" => "M8 2v4M16 2v4M3 8h18M5 4h14v16H5V4Z",
    "rotate" => "M3 12a9 9 0 1 0 3-6.7M3 4v5h5",
    "chevron-down" => "m6 9 6 6 6-6",
    "target" => "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Zm0-6a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm0-4h.01",
    "x" => "M18 6 6 18M6 6l12 12"
  }

  attr :name, :string, required: true
  attr :class, :any, default: "size-3.5"

  def icon(assigns) do
    assigns = assign(assigns, :path, Map.fetch!(@icon_paths, assigns.name))

    ~H"""
    <svg
      class={["inline-block shrink-0", @class]}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d={@path} />
    </svg>
    """
  end

  # ----------------------------------------------------------------- popover

  attr :label, :string, required: true
  attr :icon, :string, default: "info"
  attr :align, :string, default: "end"
  slot :inner_block, required: true

  def popover(assigns) do
    ~H"""
    <details class="pop relative inline-block">
      <summary class="inline-flex cursor-pointer select-none list-none items-center gap-1 rounded-md bg-base-200 px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-base-content">
        <.icon name={@icon} class="size-3" /> {@label}
      </summary>
      <div class={[
        "absolute top-full z-30 mt-1 max-h-[70vh] w-[380px] max-w-[88vw] overflow-auto rounded-lg bg-base-100 p-3 text-[11px] leading-snug shadow-lg ring-1 ring-base-300",
        @align == "end" && "end-0",
        @align == "start" && "start-0"
      ]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  # ------------------------------------------------------- shared formatting

  def num(value), do: Format.num(value)
  def signed(value), do: Format.signed(value)
  def aed(value), do: Format.aed(value)
  def aed_short(value), do: Format.aed_short(value)
  def pct(value), do: Format.pct(value)
  def pct0(value), do: Format.pct0(value)
  def signed_pct(value), do: Format.signed_pct(value)

  # --------------------------------------------------------------- gm pieces

  attr :rag, :atom, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def rag_chip(assigns) do
    ~H"""
    <span
      title={@title}
      class={[
        "inline-flex shrink-0 items-center whitespace-nowrap rounded-full px-1.5 py-[1px] text-[9px] font-bold uppercase leading-[14px] tracking-wide",
        @rag == :green && "bg-positive-soft text-positive",
        @rag == :amber && "border border-base-300 bg-transparent text-muted",
        @rag == :red && "bg-negative-soft text-negative"
      ]}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :right
  slot :inner_block, required: true

  def gm_tile(assigns) do
    ~H"""
    <div class={["flex min-w-0 flex-col rounded-lg bg-base-100 px-3 py-2 ring-1 ring-base-300", @class]}>
      <div class="flex items-center justify-between gap-1.5">
        <p
          title={@label}
          class="min-w-0 truncate text-[10px] font-extrabold uppercase leading-tight tracking-[0.08em] text-muted"
        >
          {@label}
        </p>
        {render_slot(@right)}
      </div>
      <div class="mt-0.5 flex min-h-0 flex-1 flex-col justify-center">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Month select + club select — the shared filter bar controls."
  attr :month, :string, required: true
  attr :club_id, :string, required: true
  attr :months, :list, required: true
  attr :clubs, :list, required: true
  attr :current_month, :string, required: true

  def month_club_filters(assigns) do
    ~H"""
    <form phx-change="filter" class="contents">
      <select name="month" class="select-field" aria-label={gettext("Month")}>
        <option :for={m <- @months} value={m.key} selected={m.key == @month}>
          {m.label}{if m.key == @current_month, do: " (MTD)"}
        </option>
      </select>
      <select name="club_id" class="select-field" aria-label={gettext("Club")}>
        <option value="all" selected={@club_id == "all"}>{gettext("All clubs")}</option>
        <option :for={c <- @clubs} value={c.id} selected={@club_id == c.id}>{c.name}</option>
      </select>
    </form>
    """
  end
end
