defmodule GmBmdWeb.IngestController do
  @moduledoc """
  The feed's write side. `POST /api/ingest` takes the payload documented in
  `GmBmd.Bridge.Ingest`, authenticated with `Authorization: Bearer <INGEST_TOKEN>`
  (set in the action's environment; the endpoint is disabled when unset).
  `GET /api/ingest/status` reports what is loaded.
  """

  use GmBmdWeb, :controller

  alias GmBmd.Bridge.{DB, Ingest}

  def status(conn, _params) do
    json(conn, %{
      loaded: DB.loaded?(),
      provenance: DB.provenance(),
      counts: Ingest.counts(),
      ingest_enabled: token() != nil
    })
  end

  def create(conn, params) do
    with :ok <- authorise(conn),
         {:ok, counts} <- Ingest.load!(payload(params)) do
      json(conn, %{ok: true, counts: counts, provenance: DB.provenance()})
    else
      {:error, :disabled} ->
        conn |> put_status(503) |> json(%{error: "ingest disabled: INGEST_TOKEN not set"})

      {:error, :unauthorised} ->
        conn |> put_status(401) |> json(%{error: "bad or missing bearer token"})
    end
  rescue
    error ->
      conn |> put_status(422) |> json(%{error: Exception.message(error)})
  end

  # Phoenix merges a JSON object body into params; a JSON array lands under "_json".
  defp payload(%{"_json" => body}) when is_map(body), do: body
  defp payload(params), do: params

  defp authorise(conn) do
    case token() do
      nil ->
        {:error, :disabled}

      expected ->
        with ["Bearer " <> given] <- get_req_header(conn, "authorization"),
             true <- Plug.Crypto.secure_compare(given, expected) do
          :ok
        else
          _ -> {:error, :unauthorised}
        end
    end
  end

  defp token do
    case Application.get_env(:gm_bmd, :ingest_token) do
      nil -> nil
      "" -> nil
      t -> t
    end
  end
end
