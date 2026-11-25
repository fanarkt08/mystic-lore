defmodule MlAccountsWeb.OnboardingTest do
  @moduledoc "Accueil guidé : proposé aux nouveaux comptes, terminé, passé ou relancé depuis les paramètres."
  use MlAccountsWeb.ConnCase, async: true
  alias MlAccounts.{Repo, User}

  defp put_onboarding(user, body) do
    build_conn()
    |> internal(user.id)
    |> put_req_header("content-type", "application/json")
    |> put("/api/me/onboarding", Jason.encode!(body))
  end

  test "a new account starts pending; the private user carries the state" do
    {:ok, user} =
      MlAccounts.register(%{
        "email" => "new.mage@example.test",
        "username" => "new_mage",
        "password" => password()
      })

    assert %User{onboarding_status: "pending", onboarding_at: nil} = user

    assert %{"user" => %{"onboarding" => %{"status" => "pending", "at" => nil}}} =
             build_conn() |> internal(user.id) |> get("/api/me") |> json_response(200)
  end

  test "completed or skipped: dated and remembered; pending again when restarted from the settings" do
    user = user_fixture()
    MlShared.Events.subscribe("user:#{user.id}")

    assert %{"user" => %{"onboarding" => %{"status" => "completed", "at" => at}}} =
             put_onboarding(user, %{"status" => "completed"}) |> json_response(200)

    assert is_binary(at)
    assert_receive {:profile_changed, _}
    assert %User{onboarding_status: "completed"} = Repo.reload!(user)

    assert %{"user" => %{"onboarding" => %{"status" => "skipped"}}} =
             put_onboarding(user, %{"status" => "skipped"}) |> json_response(200)

    assert %{"user" => %{"onboarding" => %{"status" => "pending", "at" => nil}}} =
             put_onboarding(user, %{"status" => "pending"}) |> json_response(200)
  end

  test "any other value is refused (422) and nothing changes" do
    user = user_fixture()

    for value <- ["done", nil, 1] do
      assert %{"errors" => %{"status" => ["is invalid"]}} =
               put_onboarding(user, %{"status" => value}) |> json_response(422)
    end

    assert %User{onboarding_status: "pending"} = Repo.reload!(user)
    assert build_conn() |> put("/api/me/onboarding", %{}) |> json_response(401)
  end
end
