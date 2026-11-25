# Fictional demo data, idempotent (mix run priv/repo/seeds.exs).
alias MlBilling.{Invoice, Local, Repo, Subscription}

# En production, seulement pour un déploiement de démo avec un SEED_DEMO_PASSWORD secret.
if Application.get_env(:billing, :env) == :prod and
     MlShared.Demo.password() == "mystic-demo-pass-1",
   do: raise("demo seeds run in production only with a secret SEED_DEMO_PASSWORD")

now = DateTime.utc_now(:second)
days = fn n -> DateTime.add(now, n, :day) end

subscriptions = [
  # lea_moreau: Premium, active, renews in 20 days
  {"lea_moreau", "premium", days.(-10), days.(20), false},
  # ines_petit: VIP, canceled at the end of the period (in 5 days)
  {"ines_petit", "vip", days.(-25), days.(5), true}
]

for {username, plan, period_start, period_end, cancel?} <- subscriptions do
  user_id = MlShared.Demo.user(username).id

  Repo.insert!(
    %Subscription{
      user_id: user_id,
      plan: plan,
      status: "active",
      provider: "local",
      provider_customer_id: Local.customer_id(user_id),
      provider_subscription_id: "sub_local_seed_#{username}",
      current_period_start: period_start,
      current_period_end: period_end,
      cancel_at_period_end: cancel?,
      last_event_at: period_start
    },
    on_conflict: {:replace_all_except, [:id, :inserted_at]},
    conflict_target: :user_id
  )
end

invoices = [
  {"lea_moreau", "in_local_seed_lea_1", 1200, days.(-40), days.(-10)},
  {"lea_moreau", "in_local_seed_lea_2", 1200, days.(-10), days.(20)},
  {"ines_petit", "in_local_seed_ines_1", 2400, days.(-25), days.(5)}
]

for {username, invoice_id, amount, period_start, period_end} <- invoices do
  Repo.insert!(
    %Invoice{
      user_id: MlShared.Demo.user(username).id,
      provider: "local",
      provider_invoice_id: invoice_id,
      provider_subscription_id: "sub_local_seed_#{username}",
      amount_cents: amount,
      currency: "usd",
      status: "paid",
      period_start: period_start,
      period_end: period_end
    },
    on_conflict: {:replace_all_except, [:id, :inserted_at]},
    conflict_target: [:provider, :provider_invoice_id]
  )
end

# AI credits of the month, through the ledger functions so that the studio's demo generations match.
month_start =
  now |> DateTime.to_date() |> Date.beginning_of_month() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

# minutes ago, kept inside the current month
ago = fn minutes -> Enum.max([DateTime.add(now, -minutes * 60), month_start], DateTime) end
gen = fn n -> "studio:gen:5d000000-0000-4000-8000-00000000000#{n}" end
alias MlBilling.Credits

lea = MlShared.Demo.user("lea_moreau").id
ines = MlShared.Demo.user("ines_petit").id

{:ok, _} = Credits.reserve(lea, 2, gen.(1), "outline", ago.(240))
{:ok, _} = Credits.consume(lea, gen.(1), ago.(239))
{:ok, _} = Credits.reserve(lea, 5, gen.(2), "lesson_draft", ago.(180))
{:ok, _} = Credits.consume(lea, gen.(2), ago.(179))
{:ok, _} = Credits.reserve(lea, 5, gen.(3), "lesson_draft", ago.(120))
{:ok, _} = Credits.release(lea, gen.(3), ago.(119))
{:ok, _} = Credits.reserve(ines, 12, gen.(4), "image", ago.(90))
{:ok, _} = Credits.consume(ines, gen.(4), ago.(89))

IO.puts(
  "billing seeds: 2 subscriptions (lea premium, ines vip canceling), 3 invoices, " <>
    "AI credits (lea #{Credits.overview(lea).account.balance}/300, ines #{Credits.overview(ines).account.balance}/1000)"
)
