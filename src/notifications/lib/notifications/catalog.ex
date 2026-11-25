defmodule MlNotifications.Catalog do
  @moduledoc """
  Catalogue de ce qui peut être notifié et du seul service autorisé à créer chaque catégorie.
  `params` ne contient jamais de texte rédigé ni d'URL : `web` en tire la phrase et le lien.
  """

  # {clé, producteur, in-app par défaut, e-mail par défaut, canaux verrouillés}
  @categories [
    {"security", "accounts", true, true, ~w(in_app email)},
    {"account", "accounts", true, true, ~w(in_app email)},
    {"billing", "billing", true, true, []},
    {"messages", "social", true, false, []},
    {"friends", "social", true, false, []},
    {"community", "community", true, false, []},
    {"multiplayer", "multiplayer", true, false, []},
    {"studio", "studio", true, false, []},
    {"learning", "learning", true, false, []}
  ]

  @plans {:enum, ~w(premium vip)}

  # params : %{clé => type} ; required : clés obligatoires ; actor : acteur obligatoire (true) ou interdit (false) ;
  # subject : {type, clé de params | :actor} enregistré avec la notification
  @kinds %{
    "password_changed" => %{
      category: "security",
      email: :center,
      actor: false,
      params: %{"method" => {:enum, ~w(settings reset)}}
    },
    "email_changed" => %{category: "security", email: :producer, actor: false, params: %{}},
    "two_factor_enabled" => %{category: "security", email: :center, actor: false, params: %{}},
    "two_factor_disabled" => %{category: "security", email: :center, actor: false, params: %{}},
    "recovery_codes_regenerated" => %{
      category: "security",
      email: :center,
      actor: false,
      params: %{}
    },
    "sessions_revoked" => %{
      category: "security",
      email: :center,
      actor: false,
      params: %{"count" => :count}
    },
    "sanction_issued" => %{
      category: "account",
      email: :producer,
      actor: false,
      params: %{
        "sanction_id" => :uuid,
        "sanction_kind" => {:enum, ~w(warning restriction)},
        "ends_at" => :datetime
      },
      required: ~w(sanction_id sanction_kind),
      subject: {"sanction", "sanction_id"}
    },
    "sanction_lifted" => %{
      category: "account",
      email: :producer,
      actor: false,
      params: %{"sanction_id" => :uuid, "sanction_kind" => {:enum, ~w(warning restriction)}},
      required: ~w(sanction_id sanction_kind),
      subject: {"sanction", "sanction_id"}
    },
    "appeal_decided" => %{
      category: "account",
      email: :producer,
      actor: false,
      params: %{"appeal_id" => :uuid, "outcome" => {:enum, ~w(accepted rejected)}},
      required: ~w(appeal_id outcome),
      subject: {"appeal", "appeal_id"}
    },
    "export_ready" => %{
      category: "account",
      email: :none,
      actor: false,
      params: %{"export_id" => :uuid},
      required: ~w(export_id),
      subject: {"export", "export_id"}
    },
    "export_failed" => %{
      category: "account",
      email: :none,
      actor: false,
      params: %{"export_id" => :uuid},
      required: ~w(export_id),
      subject: {"export", "export_id"}
    },
    # réponse du staff à une demande de support : accounts envoie déjà la réponse par e-mail
    "support_replied" => %{
      category: "account",
      email: :producer,
      actor: false,
      params: %{"request_id" => :uuid},
      required: ~w(request_id),
      subject: {"support_request", "request_id"}
    },
    "subscription_activated" => %{
      category: "billing",
      email: :center,
      actor: false,
      params: %{"plan" => @plans},
      required: ~w(plan),
      subject: {"plan", "plan"}
    },
    "payment_failed" => %{
      category: "billing",
      email: :center,
      mandatory: true,
      actor: false,
      params: %{"plan" => @plans},
      required: ~w(plan),
      subject: {"plan", "plan"}
    },
    "cancellation_scheduled" => %{
      category: "billing",
      email: :center,
      actor: false,
      params: %{"plan" => @plans, "period_end" => :datetime},
      required: ~w(plan),
      subject: {"plan", "plan"}
    },
    "subscription_ended" => %{
      category: "billing",
      email: :center,
      mandatory: true,
      actor: false,
      params: %{"plan" => @plans},
      required: ~w(plan),
      subject: {"plan", "plan"}
    },
    "message_received" => %{
      category: "messages",
      email: :center,
      actor: true,
      params: %{
        "conversation_id" => :uuid,
        "conversation_kind" => {:enum, ~w(direct group)},
        "group_name" => {:text, 60}
      },
      required: ~w(conversation_id conversation_kind),
      subject: {"conversation", "conversation_id"}
    },
    "friend_request_received" => %{
      category: "friends",
      email: :center,
      actor: true,
      params: %{"request_id" => :uuid},
      subject: {"member", :actor}
    },
    "friend_request_accepted" => %{
      category: "friends",
      email: :center,
      actor: true,
      params: %{},
      subject: {"member", :actor}
    },
    "group_added" => %{
      category: "friends",
      email: :center,
      actor: true,
      params: %{"conversation_id" => :uuid, "group_name" => {:text, 60}},
      required: ~w(conversation_id group_name),
      subject: {"conversation", "conversation_id"}
    },
    "community_reply" => %{
      category: "community",
      email: :center,
      actor: true,
      params: %{"discussion_id" => :uuid, "slug" => :slug, "title" => {:text, 140}},
      required: ~w(slug title),
      subject: {"discussion", "slug"}
    },
    "lobby_invite" => %{
      category: "multiplayer",
      email: :center,
      actor: true,
      params: %{"invite_id" => :uuid, "lobby_id" => :uuid, "lobby_title" => {:text, 60}},
      required: ~w(invite_id lobby_id lobby_title),
      subject: {"lobby", "lobby_id"}
    },
    "review_approved" => %{
      category: "studio",
      email: :center,
      actor: false,
      params: %{"project_id" => :uuid},
      required: ~w(project_id),
      subject: {"project", "project_id"}
    },
    "review_rejected" => %{
      category: "studio",
      email: :center,
      actor: false,
      params: %{"project_id" => :uuid},
      required: ~w(project_id),
      subject: {"project", "project_id"}
    },
    "badge_earned" => %{
      category: "learning",
      email: :center,
      actor: false,
      params: %{"badge_slug" => :slug, "badge_name" => {:text, 60}},
      required: ~w(badge_slug badge_name),
      subject: {"badge", "badge_slug"}
    }
  }

  @key_format ~r/\A[A-Za-z0-9:_.\-]{1,200}\z/
  @slug_format ~r/\A[a-z0-9][a-z0-9\-]{0,79}\z/
  # caractères de contrôle et contrôles bidirectionnels (usurpation d'affichage)
  @forbidden ~r/[\p{Cc}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  def categories, do: Enum.map(@categories, &elem(&1, 0))

  @doc "Catégories qu'un service appelant peut créer."
  def categories_of(svc), do: for({key, ^svc, _, _, _} <- @categories, do: key)

  @doc "Valeur par défaut d'un canal (`\"in_app\"` | `\"email\"`)."
  def default(category, "in_app"), do: category |> category!() |> elem(2)
  def default(category, "email"), do: category |> category!() |> elem(3)

  def locked(category), do: category |> category!() |> elem(4)
  def locked?(category, channel), do: channel in locked(category)

  def kind(kind), do: Map.get(@kinds, kind)
  def kinds, do: Map.keys(@kinds)

  @doc "Sortes dont l'e-mail ne se coupe pas (ce qui conditionne l'accès)."
  def mandatory?(kind), do: Map.get(@kinds[kind] || %{}, :mandatory, false)

  defp category!(key), do: List.keyfind(@categories, key, 0) || raise(ArgumentError, key)

  @doc """
  Valide une demande de création venant du service `svc` : `{:ok, attrs normalisés}`, `{:error, :forbidden}`
  (catégorie d'un autre service) ou `{:error, {:invalid, erreurs}}`.
  """
  def validate(svc, attrs) when is_map(attrs) do
    category = attrs["category"]

    cond do
      category not in categories() ->
        invalid(:category, "is invalid")

      category not in categories_of(svc) ->
        {:error, :forbidden}

      not match?(%{category: ^category}, @kinds[attrs["kind"]]) ->
        invalid(:kind, "is invalid")

      true ->
        spec = @kinds[attrs["kind"]]

        with {:ok, user_id} <- uuid(attrs["user_id"], :user_id),
             {:ok, actor_id} <- actor(attrs["actor_id"], spec),
             {:ok, params} <- params(attrs["params"] || %{}, spec),
             {:ok, key} <- key(attrs["dedupe_key"], :dedupe_key),
             {:ok, event_id} <- key(attrs["event_id"] || attrs["dedupe_key"], :event_id),
             {:ok, occurred_at} <- occurred_at(attrs["occurred_at"]) do
          {subject_type, subject_id} = subject(spec, params, actor_id)

          {:ok,
           %{
             user_id: user_id,
             category: category,
             kind: attrs["kind"],
             actor_id: actor_id,
             subject_type: subject_type,
             subject_id: subject_id,
             params: params,
             dedupe_key: key,
             event_id: event_id,
             occurred_at: occurred_at
           }}
        end
    end
  end

  def validate(_svc, _attrs), do: invalid(:base, "is invalid")

  defp actor(nil, %{actor: false}), do: {:ok, nil}
  defp actor(_actor, %{actor: false}), do: invalid(:actor_id, "must be empty for this kind")
  defp actor(actor, %{actor: true}), do: uuid(actor, :actor_id)

  defp params(params, spec) when is_map(params) do
    allowed = spec.params

    cond do
      key = Enum.find(Map.keys(params), &(not Map.has_key?(allowed, &1))) ->
        invalid(:params, "has an unknown key: #{String.slice(to_string(key), 0, 40)}")

      key = Enum.find(Map.get(spec, :required, []), &(params[&1] in [nil, ""])) ->
        invalid(:params, "is missing #{key}")

      true ->
        Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case value(allowed[key], value) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            :error -> {:halt, invalid(:params, "has an invalid #{key}")}
          end
        end)
    end
  end

  defp params(_params, _spec), do: invalid(:params, "is invalid")

  defp value(_type, nil), do: {:ok, nil}

  defp value(:uuid, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp value({:enum, values}, value), do: if(value in values, do: {:ok, value}, else: :error)
  defp value(:count, value) when is_integer(value) and value in 1..10_000, do: {:ok, value}

  defp value(:slug, value) when is_binary(value),
    do: if(Regex.match?(@slug_format, value), do: {:ok, value}, else: :error)

  defp value(:datetime, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      _ -> :error
    end
  end

  defp value({:text, max}, value) when is_binary(value) do
    text = String.trim(value)

    if String.valid?(text) and text != "" and String.length(text) <= max and
         not Regex.match?(@forbidden, text),
       do: {:ok, text},
       else: :error
  end

  defp value(_type, _value), do: :error

  defp subject(%{subject: {type, :actor}}, _params, actor_id), do: {type, actor_id}
  defp subject(%{subject: {type, key}}, params, _actor_id), do: {type, params[key]}
  defp subject(_spec, _params, _actor_id), do: {nil, nil}

  defp key(value, field) when is_binary(value) do
    if Regex.match?(@key_format, value), do: {:ok, value}, else: invalid(field, "is invalid")
  end

  defp key(_value, field), do: invalid(field, "can't be blank")

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid(field, "is invalid")
    end
  end

  defp occurred_at(nil), do: {:ok, nil}

  defp occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> invalid(:occurred_at, "is invalid")
    end
  end

  defp occurred_at(_value), do: invalid(:occurred_at, "is invalid")

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
