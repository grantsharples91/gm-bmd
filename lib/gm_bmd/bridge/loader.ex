defmodule GmBmd.Bridge.Loader do
  @moduledoc """
  Boot-time bootstrap: load the THOR snapshot shipped in
  `priv/bridge/thor_snapshot.json` when the `bridge_*` tables are empty, or
  when the bundled snapshot is newer (`generated_at`) than what the tables
  hold — so a redeploy with a fresher or richer snapshot takes effect. A
  platform sync through `POST /api/ingest` stamps its own `generated_at`, so
  it is never overwritten by an older bundled file. Manager closing overrides
  live in their own table and are untouched either way.
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

  @doc """
  Load the snapshot if the tables are empty or the snapshot is newer.
  Returns :loaded | :present | :missing.
  """
  def ensure_loaded do
    path = Application.app_dir(:gm_bmd, Path.join("priv", @snapshot))

    cond do
      not File.exists?(path) ->
        Logger.warning("bridge snapshot missing at #{path}; running on seeded data")
        :missing

      Ingest.counts().month_bridges == 0 ->
        load(path, "tables empty")

      snapshot_generated_at(path) > (Ingest.meta()["generated_at"] || "") ->
        load(path, "bundled snapshot is newer than the loaded feed")

      true ->
        DB.reload()
        :present
    end
  end

  defp load(path, why) do
    {:ok, counts} = Ingest.load_file!(path)
    Logger.info("bridge snapshot loaded (#{why}): #{inspect(counts)}")
    :loaded
  end

  # Cheap peek at the file's generated_at without decoding 1 MB of rows.
  defp snapshot_generated_at(path) do
    case Regex.run(~r/"generated_at"\s*:\s*"([^"]+)"/, File.read!(path)) do
      [_, stamp] -> stamp
      _ -> ""
    end
  end
end
