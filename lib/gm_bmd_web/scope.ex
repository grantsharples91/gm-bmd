defmodule GmBmdWeb.Scope do
  @moduledoc """
  Club selection from the filter bar. The picker posts `clubs` as a list of
  ids (checkboxes); older callers post a single `club_id`. Either becomes the
  selection string `GmBmd.Gm` understands: "all", one id, or ids joined with
  commas. Unknown ids are dropped; nothing valid means all clubs.
  """

  alias GmBmd.Bridge
  alias GmBmd.Gm

  # An explicit club_id wins over the checkbox list: the picker never sends
  # both, but a serialised form can carry the "all" checkbox alongside it.
  def from_params(%{"club_id" => club_id}) when is_binary(club_id) and club_id != "",
    do: from_ids([club_id])

  def from_params(%{"clubs" => clubs}) when is_list(clubs), do: from_ids(clubs)
  def from_params(_params), do: Gm.all_clubs()

  @doc "Validate a selection string or a list of ids against the club list."
  def from_ids(ids) when is_list(ids) do
    valid = MapSet.new(Bridge.clubs(), & &1.id)

    ids
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.reject(&(&1 == Gm.all_clubs()))
    |> Enum.filter(&MapSet.member?(valid, &1))
    |> Gm.selection()
  end

  def from_ids(club_id) when is_binary(club_id), do: from_ids([club_id])
  def from_ids(_), do: Gm.all_clubs()
end
