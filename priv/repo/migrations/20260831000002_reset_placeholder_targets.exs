defmodule GmBmd.Repo.Migrations.ResetPlaceholderTargets do
  use Ecto.Migration

  # The first boot ran on seeded placeholder data (five clubs) and auto-seeded
  # T2 targets from it. Now the THOR feed is in, drop those so
  # GmBmd.Targets.ensure_seeded/0 re-seeds from real club actuals on the next
  # request. One-off: nobody had set a target by hand yet.
  def up do
    execute "DELETE FROM gm_forecasts"
    execute "DELETE FROM target_states"
    execute "DELETE FROM targets"
  end

  def down, do: :ok
end
