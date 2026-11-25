defmodule MlBilling.Admin do
  @moduledoc """
  Lectures et ajustements de crédits pour les admins, dont le rôle est relu chez accounts à chaque appel.
  """
  import Ecto.Query
  require Logger
  alias MlBilling.{Credits, Invoice, Repo, Subscription, WebhookEvent}
  alias MlShared.Client

  @per_page 25

  @doc "`:ok` pour un admin, sinon `{:error, :forbidden}` ou `{:error, :roles_unavailable}`."
  def require_admin(user_id) do
    case Client.get(:accounts, "/api/internal/users/:id", path_params: [id: user_id]) do
      {:ok, %{"user" => %{"role" => "admin"}}} -> :ok
      {:ok, _} -> {:error, :forbidden}
      {:error, {:http, 404, _}} -> {:error, :forbidden}
      _ -> {:error, :roles_unavailable}
    end
  end

  @doc "Indicateurs réels : abonnements actifs par formule, impayés en grâce, revenus du mois (factures payées), webhooks en échec."
  def stats(now \\ DateTime.utc_now()) do
    month = DateTime.new!(Date.beginning_of_month(DateTime.to_date(now)), ~T[00:00:00], "Etc/UTC")

    active =
      Repo.all(
        from s in Subscription,
          where: s.status == "active" and s.plan in ["premium", "vip"],
          group_by: s.plan,
          select: {s.plan, count(s.id)}
      )
      |> Map.new()

    %{
      active_subscriptions: Map.merge(%{"premium" => 0, "vip" => 0}, active),
      past_due_subscriptions:
        Repo.aggregate(from(s in Subscription, where: s.status == "past_due"), :count),
      revenue_month_cents:
        Repo.one(
          from i in Invoice,
            where:
              i.status == "paid" and i.inserted_at >= ^month and
                i.currency == ^MlBilling.currency(),
            select: coalesce(sum(i.amount_cents), 0)
        ),
      currency: MlBilling.currency(),
      failed_webhook_events:
        Repo.aggregate(from(e in WebhookEvent, where: e.status == "failed"), :count)
    }
  end

  @doc "Abonnements (lecture seule), plus récemment modifiés d'abord ; filtres `status`, `plan`."
  def subscriptions(params) do
    query =
      Subscription
      |> filter(:status, params["status"], ~w(none active past_due canceled))
      |> filter(:plan, params["plan"], ~w(free premium vip))

    paginate(query, params, [desc: :updated_at], fn s ->
      Map.take(s, [
        :id,
        :user_id,
        :plan,
        :status,
        :provider,
        :current_period_end,
        :cancel_at_period_end,
        :past_due_since,
        :updated_at
      ])
    end)
  end

  @doc "Événements de webhook en échec (sans leur contenu), plus récents d'abord."
  def failed_events(params) do
    paginate(
      from(e in WebhookEvent, where: e.status == "failed"),
      params,
      [desc: :inserted_at],
      fn e ->
        Map.take(e, [
          :id,
          :provider,
          :provider_event_id,
          :type,
          :error,
          :user_id,
          :event_created_at,
          :inserted_at
        ])
      end
    )
  end

  @doc "Accorde une allocation exceptionnelle de crédits IA, qui n'est créditée que si l'audit est enregistré."
  def adjust_credits(admin_id, params) do
    with {:ok, p} <- adjustment_params(params),
         :ok <- member_exists(p.user_id) do
      Credits.adjust(p.user_id, p.amount, p.ref, fn balance ->
        audit(admin_id, "billing.credits.adjusted", "user", p.user_id, p.reason, %{
          "amount" => p.amount,
          "ref" => p.ref,
          "balance_after" => balance
        })
      end)
    end
  end

  defp adjustment_params(params) do
    types = %{user_id: Ecto.UUID, amount: :integer, reason: :string, ref: :string}

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.update_change(:reason, &String.trim/1)
    |> Ecto.Changeset.validate_required(Map.keys(types))
    |> Ecto.Changeset.validate_number(:amount, greater_than: 0, less_than_or_equal_to: 5000)
    |> Ecto.Changeset.validate_length(:reason, min: 5, max: 500)
    |> Ecto.Changeset.validate_format(:ref, ~r/^admin:[A-Za-z0-9_\-]{8,100}$/)
    |> Ecto.Changeset.apply_action(:validate)
  end

  defp member_exists(user_id) do
    case Client.get(:accounts, "/api/internal/users/:id", path_params: [id: user_id]) do
      {:ok, %{"user" => %{"id" => _}}} -> :ok
      {:error, {:http, 404, _}} -> {:error, {:invalid, %{user_id: ["is not a member"]}}}
      _ -> {:error, :roles_unavailable}
    end
  end

  defp audit(actor_id, action, target_type, target_id, reason, metadata) do
    case Client.post(:accounts, "/api/internal/audit",
           json: %{
             actor_id: actor_id,
             action: action,
             target_type: target_type,
             target_id: target_id,
             reason: reason,
             metadata: metadata
           }
         ) do
      {:ok, %{"id" => _}} ->
        :ok

      other ->
        Logger.error("audit entry #{action} not recorded: #{inspect(elem(other, 0))}")
        {:error, :audit_unavailable}
    end
  end

  defp filter(query, field, value, allowed) do
    if value in allowed, do: where(query, [x], field(x, ^field) == ^value), else: query
  end

  defp paginate(query, params, order, render) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    total = Repo.aggregate(query, :count)

    entries =
      Repo.all(
        from x in query,
          order_by: ^order,
          limit: @per_page,
          offset: ^((page - 1) * @per_page)
      )

    %{
      entries: Enum.map(entries, render),
      page: page,
      total: total,
      total_pages: max(div(total + @per_page - 1, @per_page), 1)
    }
  end
end
