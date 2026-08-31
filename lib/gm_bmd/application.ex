defmodule GmBmd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GmBmd.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:gm_bmd, :ecto_repos),
       skip: not Application.fetch_env!(:gm_bmd, :migrate_on_boot)},
      GmBmd.Bridge.Loader,
      {Phoenix.PubSub, name: GmBmd.PubSub},
      GmBmdWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: GmBmd.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GmBmdWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
