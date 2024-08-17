defmodule Sequin.ReplicationRuntime.Supervisor do
  @moduledoc """
  """
  use Supervisor

  alias Sequin.Databases.PostgresDatabase
  alias Sequin.Extensions.Replication, as: ReplicationExt
  alias Sequin.Replication.MessageHandler
  alias Sequin.Replication.PostgresReplicationSlot
  alias Sequin.ReplicationRuntime.PostgresReplicationSupervisor
  alias Sequin.Repo

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(_) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  def start_for_pg_replication(supervisor \\ PostgresReplicationSupervisor, pg_replication_or_id, opts \\ [])

  def start_for_pg_replication(supervisor, %PostgresReplicationSlot{} = pg_replication, opts) do
    pg_replication = Repo.preload(pg_replication, :postgres_database)

    default_opts = [
      id: pg_replication.id,
      slot_name: pg_replication.slot_name,
      publication: pg_replication.publication_name,
      message_handler_ctx: MessageHandler.context(pg_replication),
      message_handler_module: MessageHandler,
      connection: PostgresDatabase.to_postgrex_opts(pg_replication.postgres_database)
    ]

    opts = Keyword.merge(default_opts, opts)

    Sequin.DynamicSupervisor.start_child(supervisor, {ReplicationExt, opts})
  end

  def start_for_pg_replication(supervisor, id, opts) do
    case Sequin.Replication.get_pg_replication(id) do
      {:ok, pg_replication} -> start_for_pg_replication(supervisor, pg_replication, opts)
      error -> error
    end
  end

  def stop_for_pg_replication(supervisor \\ PostgresReplicationSupervisor, pg_replication_or_id)

  def stop_for_pg_replication(supervisor, %PostgresReplicationSlot{id: id}) do
    stop_for_pg_replication(supervisor, id)
  end

  def stop_for_pg_replication(supervisor, id) do
    Sequin.DynamicSupervisor.stop_child(supervisor, ReplicationExt.via_tuple(id))
    :ok
  end

  def restart_for_pg_replication(supervisor \\ PostgresReplicationSupervisor, pg_replication_or_id) do
    stop_for_pg_replication(supervisor, pg_replication_or_id)
    start_for_pg_replication(supervisor, pg_replication_or_id)
  end

  defp children do
    [
      Sequin.ReplicationRuntime.Starter,
      Sequin.DynamicSupervisor.child_spec(name: Sequin.ReplicationRuntime.PostgresReplicationSupervisor)
    ]
  end
end