defmodule GmBmd.Activity do
  @moduledoc """
  TODAY'S ACTIVITY — deterministic placeholder money-event feed for the
  dashboard's activity tab. Seeded per calendar day so the feed is stable
  within a day and fresh the next. Replaced by the live transaction feed when
  the database plug-in lands.
  """

  alias GmBmd.Bridge

  @first ~w(Sara Omar Aisha Khalid Fatima Yousef Mariam Rashid Layla Hamdan Noura Tariq James Priya Dmitri Chiara Ahmed Reem Bilal Hana)
  @last ["Ahmed", "Al Marri", "Haddad", "Khan", "Rahman", "Osman", "Nasser", "Sultan", "Farouk", "Mansoori", "Whitfield", "Menon", "Petrov", "Rossi", "Saeed", "Jaber"]
  @plans ["Monthly AED 199", "Monthly AED 249", "Monthly AED 299", "PIF 12-month"]
  @fail_reasons ["insufficient funds", "expired card", "card declined", "bank rejected"]
  @refund_reasons ["goodwill", "duplicate charge", "cooling-off"]
  @cancel_reasons ["changed mind", "relocating", "card never authorised"]

  @event_meta %{
    collected: %{label: "Payment collected", tone: :green},
    default: %{label: "Payment failed", tone: :red},
    default_recovered: %{label: "Default recovered", tone: :green},
    prior_recovery: %{label: "Prior-month recovery", tone: :green},
    upfront: %{label: "Upfront / PIF sale", tone: :yellow},
    refund: %{label: "Refund issued", tone: :red},
    cancellation: %{label: "Cancelled before first payment", tone: :grey}
  }

  @weights [
    collected: 40,
    default: 15,
    default_recovered: 12,
    prior_recovery: 9,
    upfront: 10,
    refund: 6,
    cancellation: 8
  ]

  def event_meta, do: @event_meta

  @doc "Money events for today, newest first, optionally scoped to one club."
  def todays_events(club_id \\ "all") do
    all_events()
    |> Enum.filter(&GmBmd.Gm.in_scope?(club_id, &1.club_id))
  end

  def collected_today(events) do
    events
    |> Enum.filter(&(&1.kind in [:collected, :upfront, :default_recovered, :prior_recovery]))
    |> Enum.map(& &1.aed)
    |> Enum.sum()
  end

  def signed_amount(%{kind: kind, aed: aed}) when kind in [:refund, :default, :cancellation],
    do: -aed

  def signed_amount(%{aed: aed}), do: aed

  defp all_events do
    today = DateTime.utc_now() |> DateTime.add(4 * 3600, :second) |> DateTime.to_date()
    key = {__MODULE__, :events, today}

    case :persistent_term.get(key, :miss) do
      :miss ->
        events = generate(today)
        :persistent_term.put(key, events)
        events

      events ->
        events
    end
  end

  defp generate(today) do
    now_hour =
      DateTime.utc_now() |> DateTime.add(4 * 3600, :second) |> Map.fetch!(:hour) |> max(9)

    clubs = Bridge.clubs()

    state =
      :rand.seed_s(
        :exsss,
        {:erlang.phash2({today, :a}, 1_000_000), :erlang.phash2({today, :b}, 1_000_000),
         :erlang.phash2({today, :c}, 1_000_000)}
      )

    {events, _} =
      Enum.map_reduce(1..62, state, fn i, s ->
        {kind, s} = pick_kind(s)
        {club, s} = pick(clubs, s)
        {hour_f, s} = :rand.uniform_s(s)
        {minute_f, s} = :rand.uniform_s(s)
        {first, s} = pick(@first, s)
        {last, s} = pick(@last, s)
        {plan, s} = pick(@plans, s)
        {aed, s} = amount_for(kind, s)
        {stream, s} = stream_for(kind, s)
        {reason, s} = reason_for(kind, s)
        {tenure_f, s} = :rand.uniform_s(s)

        hour = 7 + trunc(hour_f * (now_hour - 7 + 1))
        minute = trunc(minute_f * 60)

        event = %{
          id: "evt-#{i}",
          kind: kind,
          club_id: club.id,
          club_name: club.name,
          member_name: "#{String.first(first)}. #{last}",
          member_full_name: "#{first} #{last}",
          plan: if(kind == :upfront, do: "PIF 12-month", else: plan),
          aed: aed,
          stream: stream,
          reason: reason,
          at: Time.new!(min(hour, 23), min(minute, 59), 0),
          tenure_months: 1 + trunc(tenure_f * 34)
        }

        {event, s}
      end)

    Enum.sort_by(events, & &1.at, {:desc, Time})
  end

  defp pick_kind(state) do
    total = @weights |> Keyword.values() |> Enum.sum()
    {f, state} = :rand.uniform_s(state)
    target = f * total

    {kind, _} =
      Enum.reduce_while(@weights, {nil, target}, fn {kind, w}, {_k, left} ->
        left = left - w
        if left <= 0, do: {:halt, {kind, left}}, else: {:cont, {kind, left}}
      end)

    {kind || :collected, state}
  end

  defp pick(list, state) do
    {f, state} = :rand.uniform_s(state)
    {Enum.at(list, trunc(f * length(list))), state}
  end

  defp amount_for(:upfront, state), do: pick([1999, 2499, 2999, 3499], state)

  defp amount_for(:refund, state) do
    {f, state} = :rand.uniform_s(state)
    {round(199 + f * 800), state}
  end

  defp amount_for(:cancellation, state), do: pick([199, 249, 299], state)
  defp amount_for(_kind, state), do: pick([199, 219, 249, 279, 299, 349], state)

  defp stream_for(:upfront, state), do: {"Upfront / PIF", state}
  defp stream_for(:default_recovered, state), do: {"Default recovery", state}
  defp stream_for(:prior_recovery, state), do: {"Prior-month recovery", state}
  defp stream_for(:refund, state), do: {"Refund", state}
  defp stream_for(:cancellation, state), do: {"Cancellation", state}
  defp stream_for(:default, state), do: {"Recurring (failed)", state}

  defp stream_for(_kind, state),
    do: pick(["Recurring", "Upfront", "Joining fee", "Add-on (PT)", "Add-on (locker)"], state)

  defp reason_for(:default, state), do: pick(@fail_reasons, state)
  defp reason_for(:refund, state), do: pick(@refund_reasons, state)
  defp reason_for(:cancellation, state), do: pick(@cancel_reasons, state)
  defp reason_for(_kind, state), do: {nil, state}
end
