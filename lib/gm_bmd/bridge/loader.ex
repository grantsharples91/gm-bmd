defmodule GmBmd.Bridge.Loader do
  @moduledoc """
  Boot-time bootstrap: when the `bridge_*` tables are empty, load the THOR
  snapshot shipped in `priv/bridge/thor_snapshot.json` so a fresh deploy
  shows real club data before the platform sync has run. Never overwrites a
  feed that is already in the database.
  """

  require Logger

  alias GmBmd.Bridge.{DB, Ingest}

  @snapshot "bridge/thor_snapshot.json"

  def child_spec(_opts) do
    %{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :temporary}
  end

  def run do
    if Application.get_env(:gm_bmd, :load_bridge_on_boot, false), do: ensure_loaded()
    :ok
  rescue
    error ->
      Logger.error("bridge loader failed: #{Exception.message(error)}")
      :ok
  end

  @doc "Load the snapshot if the tables are empty. Returns :loaded | :present | :missing."
  def ensure_loaded do
    path = Application.app_dir(:gm_bmd, Path.join("priv", @snapshot))

    cond do
      Ingest.counts().month_bridges > 0 ->
        DB.reload()
        :present

      not File.exists?(path) ->
        Logger.warning("bridge snapshot missing at #{path}; running on seeded data")
        :missing

      true ->
        {:ok, counts} = Ingest.load_file!(path)
        Logger.info("bridge snapshot loaded: #{inspect(counts)}")
        :loaded
    end
  end
end
