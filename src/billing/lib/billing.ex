defmodule MlBilling do
  @moduledoc """
  Plans, checkout, subscriptions and entitlements.
  A plan only changes through signed webhook events: a checkout return URL never activates anything.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias MlBilling.{CheckoutSession, Invoice, Local, Repo, Stripe, Subscription}

  @paid_plans ~w(premium vip)
  @grace_days 3
  @checkout_ttl 3600

  ## Mode and plans

  def mode do
    cond do
      Stripe.configured?() -> :stripe
      local_allowed?() -> :local
      true -> :disabled
    end
  end

  defp local_allowed? do
    flag = Application.get_env(:billing, :local_mode)
    if Application.get_env(:billing, :env) == :prod, do: flag == "true", else: flag != "false"
  end

  def currency, do: Application.fetch_env!(:billing, :currency)

  def plans do
    for plan <- Application.fetch_env!(:billing, :plans),
        do: Map.merge(plan, %{currency: currency(), interval: "month"})
  end

  def plan(key), do: Enum.find(plans(), &(&1.key == key))

  ## Entitlements

  def entitlements(user_id, now \\ DateTime.utc_now()),
    do: to_entitlements(user_id, Repo.get_by(Subscription, user_id: user_id), now)

  defp to_entitlements(user_id, nil, _now),
    do: %{
      user_id: user_id,
      plan: "free",
      status: "none",
      current_period_end: nil,
      cancel_at_period_end: false
    }

  defp to_entitlements(user_id, sub, now),
    do: %{
      user_id: user_id,
      plan: effective_plan(sub, now),
      status: sub.status,
      current_period_end: sub.current_period_end,
      cancel_at_period_end: sub.cancel_at_period_end
    }

  @doc """
  Plan granted at `now`: `active` (until the period end once canceled), `past_due` during a
  #{@grace_days}-day grace period from the first failed payment, otherwise `free`.
  """
  def effective_plan(
        %Subscription{
          status: "active",
          cancel_at_period_end: true,
          current_period_end: %DateTime{} = end_at
        } = sub,
        now
      ),
      do: if(DateTime.before?(now, end_at), do: sub.plan, else: "free")

  def effective_plan(%Subscription{status: "active", plan: plan}, _now), do: plan

  def effective_plan(%Subscription{status: "past_due", past_due_since: %DateTime{} = t} = s, now),
    do: if(DateTime.before?(now, DateTime.add(t, @grace_days, :day)), do: s.plan, else: "free")

  def effective_plan(_sub, _now), do: "free"

  @doc """
  Publishes `{:entitlements_changed, user_id, plan}` on `\"entitlements\"` and `\"user:<id>\"`, after
  applying the change to the AI credits (an upgrade tops the current month up at once).
  """
  def broadcast(%Subscription{user_id: user_id} = sub) do
    MlBilling.Credits.sync_plan(user_id)
    message = {:entitlements_changed, user_id, effective_plan(sub, DateTime.utc_now())}
    MlShared.Events.broadcast("entitlements", message)
    MlShared.Events.broadcast(MlShared.Events.user(user_id), message)
  end

  def overview(user_id) do
    invoices =
      Repo.all(
        from i in Invoice,
          where: i.user_id == ^user_id,
          order_by: [desc_nulls_last: i.period_start, desc: i.inserted_at],
          limit: 50
      )

    %{entitlements: entitlements(user_id), invoices: invoices, mode: mode()}
  end

  ## Checkout

  @doc "Opens a checkout session, which activates nothing until the signed events arrive."
  def create_checkout(user_id, params) do
    case mode() do
      :disabled ->
        {:error, :payments_disabled}

      mode ->
        with {:ok, attrs} <-
               validate(
                 params,
                 %{plan: :string, success_url: :string, cancel_url: :string},
                 &checkout_rules/1
               ),
             :ok <- not_subscribed(user_id, attrs.plan),
             do: start_checkout(mode, user_id, attrs)
    end
  end

  defp checkout_rules(changeset) do
    changeset
    |> Changeset.validate_inclusion(:plan, @paid_plans)
    |> validate_url(:success_url)
    |> validate_url(:cancel_url)
  end

  # Same plan already active: 409. Another plan starts a new checkout that replaces the current one once paid.
  defp not_subscribed(user_id, plan) do
    case entitlements(user_id) do
      %{status: "active", plan: ^plan} -> {:error, :already_subscribed}
      _ -> :ok
    end
  end

  defp start_checkout(:local, user_id, %{plan: plan}) do
    id = Ecto.UUID.generate()
    insert_session!(id, user_id, plan, "local", Local.session_ref(id))
    {:ok, %{url: "/membership/local-checkout/" <> id, session_id: id, mode: "local"}}
  end

  defp start_checkout(:stripe, user_id, %{plan: plan} = attrs) do
    id = Ecto.UUID.generate()
    expires_at = DateTime.add(DateTime.utc_now(:second), @checkout_ttl)
    metadata = [{"user_id", user_id}, {"plan", plan}]

    form =
      [
        {"mode", "subscription"},
        {"line_items[0][price]", Stripe.price_id(plan)},
        {"line_items[0][quantity]", "1"},
        {"client_reference_id", user_id},
        {"success_url", String.replace(attrs.success_url, "{CHECKOUT_SESSION_ID}", id)},
        {"cancel_url", String.replace(attrs.cancel_url, "{CHECKOUT_SESSION_ID}", id)},
        {"expires_at", to_string(DateTime.to_unix(expires_at))}
      ] ++
        for({k, v} <- metadata, do: {"metadata[#{k}]", v}) ++
        for({k, v} <- metadata, do: {"subscription_data[metadata][#{k}]", v}) ++
        for(customer <- List.wrap(stripe_customer(user_id)), do: {"customer", customer})

    case Stripe.create_checkout_session(form, id) do
      {:ok, %{"id" => ref, "url" => url}} when is_binary(ref) and is_binary(url) ->
        insert_session!(id, user_id, plan, "stripe", ref, expires_at)
        {:ok, %{url: url, session_id: id, mode: "stripe"}}

      _error ->
        {:error, :provider_error}
    end
  end

  defp insert_session!(id, user_id, plan, provider, ref, expires_at \\ nil) do
    Repo.insert!(%CheckoutSession{
      id: id,
      user_id: user_id,
      plan: plan,
      provider: provider,
      provider_session_id: ref,
      expires_at: expires_at || DateTime.add(DateTime.utc_now(:second), @checkout_ttl)
    })
  end

  defp stripe_customer(user_id) do
    Repo.one(
      from s in Subscription,
        where:
          s.user_id == ^user_id and s.provider == "stripe" and not is_nil(s.provider_customer_id),
        select: s.provider_customer_id
    )
  end

  @doc "Checkout session of this user only (another user's session is `:not_found`)."
  def get_checkout(user_id, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %CheckoutSession{} = session <- Repo.get_by(CheckoutSession, id: uuid, user_id: user_id) do
      {:ok, session}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Local mode only: simulated payment (`succeeded` | `failed`), see `MlBilling.Local`."
  def simulate_payment(user_id, id, params) do
    with {:ok, session} <- local_checkout(user_id, id),
         {:ok, %{outcome: outcome}} <-
           validate(
             params,
             %{outcome: :string},
             &Changeset.validate_inclusion(&1, :outcome, ~w(succeeded failed))
           ) do
      case {CheckoutSession.status(session), outcome} do
        {"open", _} -> Local.simulate_payment(session, outcome)
        # replay after success: idempotent, nothing to do
        {"completed", "succeeded"} -> :ok
        {"completed", _} -> {:error, :checkout_completed}
        {"expired", _} -> {:error, :checkout_expired}
      end
    end
  end

  defp local_checkout(user_id, id) do
    case {mode(), get_checkout(user_id, id)} do
      {:local, {:ok, %CheckoutSession{provider: "local"} = session}} -> {:ok, session}
      _ -> {:error, :not_found}
    end
  end

  ## Subscription management

  @doc "Cancellation at the end of the paid period (access kept until then)."
  def cancel(user_id), do: set_cancel(user_id, true)
  def resume(user_id), do: set_cancel(user_id, false)

  defp set_cancel(user_id, flag) do
    sub = Repo.get_by(Subscription, user_id: user_id)

    cond do
      is_nil(sub) or sub.status not in ~w(active past_due) or not running?(sub) ->
        {:error, :not_found}

      sub.cancel_at_period_end == flag ->
        {:ok, entitlements(user_id)}

      true ->
        with :ok <- request_cancel(sub, flag), do: {:ok, entitlements(user_id)}
    end
  end

  defp running?(%Subscription{current_period_end: %DateTime{} = end_at}),
    do: DateTime.before?(DateTime.utc_now(), end_at)

  defp running?(_sub), do: false

  defp request_cancel(%Subscription{provider: "local"} = sub, flag),
    do: Local.set_cancel_at_period_end(sub, flag)

  # Stripe: the flag returned by Stripe's API is applied at once (no plan change); the
  # customer.subscription.updated webhook that follows carries the same state.
  defp request_cancel(%Subscription{provider: "stripe"} = sub, flag) do
    case Stripe.set_cancel_at_period_end(sub.provider_subscription_id, flag) do
      {:ok, %{"cancel_at_period_end" => ^flag}} ->
        {_count, updated} =
          from(s in Subscription,
            where:
              s.id == ^sub.id and s.provider_subscription_id == ^sub.provider_subscription_id,
            select: s
          )
          |> Repo.update_all(
            set: [cancel_at_period_end: flag, updated_at: DateTime.utc_now(:second)]
          )

        Enum.each(updated, &MlBilling.Notices.transition!(sub, &1))
        Enum.each(updated, &broadcast/1)

      _error ->
        {:error, :provider_error}
    end
  end

  @doc "Stripe Customer Portal session (Stripe mode and a known Stripe customer only)."
  def portal(user_id, params) do
    with customer when is_binary(customer) <- mode() == :stripe && stripe_customer(user_id),
         {:ok, %{return_url: url}} <-
           validate(params, %{return_url: :string}, &validate_url(&1, :return_url)) do
      case Stripe.create_portal_session(customer, url) do
        {:ok, %{"url" => portal_url}} when is_binary(portal_url) -> {:ok, portal_url}
        _error -> {:error, :provider_error}
      end
    else
      {:error, %Changeset{}} = invalid -> invalid
      _ -> {:error, :not_found}
    end
  end

  ## Validation (schemaless changesets → 422)

  defp validate(params, types, rules) do
    {%{}, types}
    |> Changeset.cast(params, Map.keys(types))
    |> Changeset.validate_required(Map.keys(types))
    |> rules.()
    |> Changeset.apply_action(:validate)
  end

  defp validate_url(changeset, field) do
    Changeset.validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and host not in [nil, ""] ->
          []

        _ ->
          [{field, "must be an absolute http(s) URL"}]
      end
    end)
  end
end
