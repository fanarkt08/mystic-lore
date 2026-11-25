defmodule MlLearning.EntitlementsTest do
  # Le cache ETS est global : chaque test utilise des user_id neufs.
  use ExUnit.Case, async: true
  import MlLearning.Fixtures
  alias MlLearning.Entitlements

  test "premium access follows billing's effective plan (past_due grace included)" do
    for {plan, status, expected} <- [
          {"premium", "active", true},
          {"vip", "active", true},
          {"free", "none", false},
          {"premium", "canceled", false},
          # billing renvoie encore "vip" pendant les 3 jours de grâce d'un impayé : l'accès est conservé
          {"vip", "past_due", true},
          {"free", "past_due", false}
        ] do
      stub_billing(plan, status)
      assert Entitlements.premium?(user_id()) == {:ok, expected}, "#{plan}/#{status}"
    end
  end

  test "check/2 maps entitlements to access; free content never calls billing" do
    stub_billing("free", "none")
    assert Entitlements.check(%{premium: false}, user_id()) == :ok
    refute_received {:billing_called, _}

    assert Entitlements.check(%{premium: true}, user_id()) == {:error, :premium_required}
    assert_received {:billing_called, _}
  end

  test "answers are cached, and the \"entitlements\" event invalidates the user's entry" do
    user = user_id()
    stub_billing("free", "none")
    assert Entitlements.premium?(user) == {:ok, false}
    assert_received {:billing_called, ^user}

    stub_billing("premium")
    assert Entitlements.premium?(user) == {:ok, false}
    refute_received {:billing_called, _}

    MlShared.Events.broadcast("entitlements", {:entitlements_changed, user, "premium"})
    :sys.get_state(Entitlements)

    assert Entitlements.premium?(user) == {:ok, true}
    assert_received {:billing_called, ^user}
  end

  test "billing unreachable or failing: premium is refused, and the failure is not cached" do
    user = user_id()
    stub_billing_down()
    assert Entitlements.premium?(user) == {:error, :unavailable}
    assert Entitlements.check(%{premium: true}, user) == {:error, :entitlements_unavailable}

    Req.Test.stub(
      MlShared.Client,
      &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"}))
    )

    assert Entitlements.premium?(user) == {:error, :unavailable}

    stub_billing("premium")
    assert Entitlements.check(%{premium: true}, user) == :ok
  end
end
