defmodule Sequin.GCP.PubSub do
  @moduledoc false

  import Sequin.Error.Guards, only: [is_error: 1]

  alias Sequin.Error

  require Logger

  @pubsub_base_url "https://pubsub.googleapis.com/v1"

  # 55 minutes, tokens are valid for 1 hour
  @token_expiry_seconds 3300
  @pubsub_scope "https://www.googleapis.com/auth/pubsub"

  @cache_prefix "gcp_auth_token:"

  defmodule Client do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :project_id, String.t(), enforce: true
      field :credentials, map(), enforce: true
      field :auth_token, String.t()
      field :req_opts, keyword(), enforce: true
    end
  end

  def cache_prefix, do: @cache_prefix

  @doc """
  Creates a new PubSub client with the given project ID and credentials.
  Credentials should be a decoded Google service account JSON.
  """
  @spec new(String.t(), map(), keyword()) :: Client.t()
  def new(project_id, credentials, req_opts \\ []) do
    req_opts = Keyword.merge(default_req_opts(), req_opts)

    %Client{
      project_id: project_id,
      credentials: credentials,
      auth_token: nil,
      req_opts: req_opts
    }
  end

  @doc """
  Gets metadata about a Pub/Sub topic including statistics.
  Returns topic configuration and message count statistics.
  """
  @spec topic_metadata(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def topic_metadata(%Client{} = client, topic_id) do
    path = topic_path(client.project_id, topic_id)

    case authenticated_request(client, :get, path) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_topic_metadata(body)}

      error ->
        handle_error(error, "get topic metadata")
    end
  end

  @doc """
  Publishes a batch of messages to a Pub/Sub topic.
  Messages should be a list of maps with :data and optional :attributes fields.
  """
  @spec publish_messages(Client.t(), String.t(), list(map())) :: :ok | {:error, Error.t()}
  def publish_messages(%Client{} = client, topic_id, messages) when is_list(messages) do
    path = "#{topic_path(client.project_id, topic_id)}:publish"

    encoded_messages =
      Enum.map(messages, fn msg ->
        %{
          "data" => Base.encode64(Jason.encode!(msg.data)),
          "attributes" => msg[:attributes] || %{}
        }
      end)

    payload = %{
      "messages" => encoded_messages
    }

    case authenticated_request(client, :post, path, json: payload) do
      {:ok, %{status: 200}} ->
        :ok

      error ->
        handle_error(error, "publish messages")
    end
  end

  # Private helpers

  defp handle_error(error, req_desc) do
    case error do
      {:ok, %{status: 404}} ->
        {:error, Error.not_found(entity: :pubsub_topic)}

      {:error, error} when is_error(error) ->
        {:error, error}

      {:ok, %{body: %{"error" => error} = body}} ->
        {:error,
         Error.service(
           service: :google_pubsub,
           message: "Request failed: #{req_desc}, error: #{error}",
           details: body
         )}

      {:ok, res} ->
        {:error,
         Error.service(
           service: :google_pubsub,
           message: "Request failed: #{req_desc}, bad status (status=#{res.status})",
           details: res
         )}

      {:error, error} ->
        {:error, Error.service(service: :google_pubsub, message: "Failed to get topic metadata", details: error)}
    end
  end

  defp authenticated_request(%Client{} = client, method, path, opts \\ []) do
    case ensure_auth_token(client) do
      {:ok, token} ->
        headers = [
          {"authorization", "Bearer #{token}"},
          {"content-type", "application/json"}
        ]

        [
          method: method,
          url: "#{@pubsub_base_url}/#{path}",
          headers: headers
        ]
        |> Req.new()
        |> Req.merge(client.req_opts)
        |> Req.merge(opts)
        |> Req.request()

      error ->
        error
    end
  end

  defp ensure_auth_token(%Client{} = client) do
    cache_key = @cache_prefix <> cache_key(client.credentials)

    case ConCache.get(Sequin.Cache, cache_key) do
      nil ->
        generate_and_cache_token(client, cache_key)

      token ->
        {:ok, token}
    end
  end

  # Hash the credentials to generate a (safe) cache key
  def cache_key(credentials) do
    credentials
    |> Map.take(["client_email", "private_key"])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp generate_and_cache_token(client, cache_key) do
    with {:ok, token} <- generate_jwt_token(client) do
      # Store with TTL slightly less than token expiry
      ConCache.put(Sequin.Cache, cache_key, %ConCache.Item{
        value: token,
        ttl: :timer.seconds(@token_expiry_seconds)
      })

      {:ok, token}
    end
  end

  defp generate_jwt_token(%Client{} = client) do
    now = System.system_time(:second)

    claims = %{
      "iss" => client.credentials["client_email"],
      "scope" => @pubsub_scope,
      "aud" => "https://oauth2.googleapis.com/token",
      "exp" => now + 3600,
      "iat" => now
    }

    with {:ok, jwt} <- sign_jwt(claims, client.credentials["private_key"]) do
      exchange_jwt_for_token(jwt, client.req_opts)
    end
  end

  @spec sign_jwt(map(), String.t()) :: {:ok, String.t()}
  defp sign_jwt(claims, private_key) do
    # Parse the PEM formatted private key
    jwk = JOSE.JWK.from_pem(private_key)

    # Create the JWT with header and claims
    jws = %{"alg" => "RS256"}
    jwt = JOSE.JWT.from_map(claims)

    # Sign the JWT and convert to compact form
    {_, signed} = JOSE.JWT.sign(jwk, jws, jwt)
    compact = signed |> JOSE.JWS.compact() |> elem(1)
    {:ok, compact}
  end

  defp exchange_jwt_for_token(jwt, req_opts) do
    body =
      URI.encode_query(%{
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    req =
      [base_url: "https://oauth2.googleapis.com/token", headers: headers, body: body, method: :post]
      |> Req.new()
      |> Req.merge(req_opts)

    case Req.request(req) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Error.service(
           service: :google_pubsub,
           message: "Failed to exchange JWT for access token",
           details: %{status: status, body: body}
         )}

      {:error, _} = error ->
        error
    end
  end

  defp topic_path(project_id, topic_id) do
    "projects/#{project_id}/topics/#{topic_id}"
  end

  defp parse_topic_metadata(body) do
    %{
      "name" => name,
      "labels" => labels,
      "messageStoragePolicy" => storage_policy,
      "kmsKeyName" => kms_key,
      "schemaSettings" => schema_settings,
      "messageRetentionDuration" => retention
    } = body

    %{
      name: name,
      labels: labels || %{},
      storage_policy: storage_policy,
      kms_key: kms_key,
      schema_settings: schema_settings,
      message_retention: retention
    }
  end

  defp default_req_opts do
    Application.get_env(:sequin, :google_pubsub, [])[:req_opts] || []
  end
end