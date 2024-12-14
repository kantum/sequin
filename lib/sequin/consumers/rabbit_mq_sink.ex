defmodule Sequin.Consumers.RabbitMqSink do
  @moduledoc false
  use Ecto.Schema
  use TypedEctoSchema

  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:host, :port, :exchange]}
  @primary_key false
  typed_embedded_schema do
    field :type, Ecto.Enum, values: [:rabbitmq], default: :rabbitmq
    field :host, :string
    field :port, :integer
    field :exchange, :string
    field :connection_id, :string
  end

  def changeset(struct, params) do
    struct
    |> cast(params, [
      :host,
      :port,
      :exchange
    ])
    |> validate_required([:host, :port, :exchange])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_length(:exchange, max: 255)
    |> put_connection_id()
  end

  defp put_connection_id(changeset) do
    case get_field(changeset, :connection_id) do
      nil -> put_change(changeset, :connection_id, Ecto.UUID.generate())
      _ -> changeset
    end
  end

  def ipv6?(%__MODULE__{} = sink) do
    case :inet.getaddr(to_charlist(sink.host), :inet) do
      {:ok, _} -> false
      {:error, _} -> true
    end
  end
end