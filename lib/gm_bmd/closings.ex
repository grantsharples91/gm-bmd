defmodule GmBmd.Closings do
  @moduledoc """
  Month-end closing overrides.

  Opening transactions for a month are the prior month's closing — always.
  The system computes each month's closing from the bridge, but the feed can
  be wrong, so a site manager can set the closing for a club-month by hand.
  The override becomes the opening of the following month; the overridden
  month itself still shows what the system computed, with the manager's
  figure alongside, so the correction is visible rather than silent.
  """

  import Ecto.Query

  alias GmBmd.Bridge.DB
  alias GmBmd.Closings.ClosingOverride
  alias GmBmd.Repo

  @doc "All overrides as %{{club_id, month} => %{value, set_by, note, set_at}}."
  def all do
    ClosingOverride
    |> Repo.all()
    |> Map.new(fn o ->
      {{o.club_id, o.month}, %{value: o.value, set_by: o.set_by, note: o.note, set_at: o.updated_at}}
    end)
  end

  def get(club_id, month) do
    Repo.one(from(o in ClosingOverride, where: o.club_id == ^club_id and o.month == ^month))
  end

  @doc "Set (or replace) the closing for a club-month. Rebuilds the feed cache."
  def set(club_id, month, value, by, note \\ nil) do
    value = value |> round() |> max(0)

    Repo.insert!(
      ClosingOverride.changeset(%ClosingOverride{}, %{
        club_id: club_id,
        month: month,
        value: value,
        set_by: by,
        note: note
      }),
      on_conflict: [set: [value: value, set_by: by, note: note, updated_at: DateTime.utc_now()]],
      conflict_target: [:month, :club_id]
    )

    DB.reload()
    :ok
  end

  @doc "Remove the override — the system closing carries again."
  def clear(club_id, month) do
    Repo.delete_all(from(o in ClosingOverride, where: o.club_id == ^club_id and o.month == ^month))
    DB.reload()
    :ok
  end
end
