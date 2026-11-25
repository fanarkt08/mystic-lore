defmodule MlAccountsWeb.MeSecurityTest do
  use MlAccountsWeb.ConnCase, async: true
  alias MlAccounts.{Throttle, User, UserToken}

  @new_email "new.home@example.test"

  setup do
    %{user: user_fixture()}
  end

  defp call(user, method, path, params),
    do: build_conn() |> internal(user.id) |> dispatch(@endpoint, method, path, params)

  defp ago(amount, unit), do: DateTime.add(DateTime.utc_now(:second), -amount, unit)

  describe "current password attempts" do
    test "5 failures in 15 minutes: 429 on password change, even with the right password", %{
      user: user
    } do
      wrong = %{current_password: "not the password", password: "brand new passphrase"}
      right = %{current_password: password(), password: "brand new passphrase"}

      for _ <- 1..5 do
        assert %{"error" => "invalid_credentials"} =
                 call(user, :put, "/api/me/password", wrong) |> json_response(401)
      end

      assert %{"error" => "locked"} =
               call(user, :put, "/api/me/password", right) |> json_response(429)

      # même compteur pour les autres vérifications du mot de passe actuel
      assert %{"error" => "locked"} =
               call(user, :post, "/api/me/email", %{email: @new_email, password: password()})
               |> json_response(429)

      assert {:ok, _token, _user} = MlAccounts.login(user.email, password())

      Repo.update_all(Throttle, set: [inserted_at: ago(15, :minute)])
      assert call(user, :put, "/api/me/password", right) |> response(204)
    end

    test "the limit is per member", %{user: user} do
      for _ <- 1..5, do: MlAccounts.verify_password(user, "not the password")
      assert {:error, :locked} = MlAccounts.verify_password(user, password())
      assert :ok = MlAccounts.verify_password(user_fixture(), password())
    end
  end

  describe "POST /api/me/email" do
    test "emails a link to the NEW address and an alert to the old one; nothing changes yet", %{
      user: user
    } do
      assert call(user, :post, "/api/me/email", %{
               email: " New.Home@Example.test ",
               password: password()
             })
             |> response(204)

      assert_received {:email, confirmation}
      assert confirmation.to == [{user.display_name, @new_email}]
      assert confirmation.subject == "Confirm your new MysticLore email address"

      assert confirmation.text_body =~
               ~r"http://localhost:4000/settings/confirm-email/[A-Za-z0-9_-]{43}\n"

      assert_received {:email, notice}
      assert notice.to == [{user.display_name, user.email}]
      assert notice.text_body =~ "n•••@example.test"
      refute notice.text_body =~ @new_email

      assert Repo.get!(User, user.id).email == user.email
      assert [%UserToken{context: "change_email", sent_to: @new_email}] = Repo.all(UserToken)
    end

    test "needs the password, a valid and free address different from the current one", %{
      user: user
    } do
      taken = user_fixture()

      assert %{"error" => "invalid_credentials"} =
               call(user, :post, "/api/me/email", %{email: @new_email, password: "nope nope nope"})
               |> json_response(401)

      for {email, message} <- [
            {"not an email", "must have the @ sign and no spaces"},
            {String.upcase(taken.email), "has already been taken"},
            {String.upcase(user.email), "did not change"},
            {"", "can't be blank"}
          ] do
        assert %{"errors" => %{"email" => [^message]}} =
                 call(user, :post, "/api/me/email", %{email: email, password: password()})
                 |> json_response(422)
      end

      refute_received {:email, _}
    end

    test "at most 3 requests per hour", %{user: user} do
      for _ <- 1..3 do
        assert call(user, :post, "/api/me/email", %{email: @new_email, password: password()})
               |> response(204)
      end

      assert %{"error" => "rate_limited"} =
               call(user, :post, "/api/me/email", %{email: @new_email, password: password()})
               |> json_response(429)
    end
  end

  describe "POST /api/me/email/confirm" do
    setup %{user: user} do
      call(user, :post, "/api/me/email", %{email: @new_email, password: password()})
      assert_received {:email, %{text_body: body}}
      assert_received {:email, _notice}
      [_, token] = Regex.run(~r{/settings/confirm-email/([A-Za-z0-9_-]+)\n}, body)
      %{token: token}
    end

    test "applies the change once", %{user: user, token: token} do
      assert %{"user" => %{"email" => @new_email, "confirmed" => true}} =
               call(user, :post, "/api/me/email/confirm", %{token: token}) |> json_response(200)

      assert %{"error" => "not_found"} =
               call(Repo.reload!(user), :post, "/api/me/email/confirm", %{token: token})
               |> json_response(404)

      assert {:ok, _token, _user} = MlAccounts.login(@new_email, password())
      assert {:error, :invalid_credentials} = MlAccounts.login(user.email, password())
    end

    test "only the member who asked can use the link", %{token: token} do
      intruder = user_fixture()

      assert %{"error" => "not_found"} =
               call(intruder, :post, "/api/me/email/confirm", %{token: token})
               |> json_response(404)

      assert Repo.get!(User, intruder.id).email == intruder.email
    end

    test "expires after 24 hours; a new request replaces the previous link", %{
      user: user,
      token: token
    } do
      Repo.update_all(UserToken, set: [inserted_at: ago(24, :hour)])

      assert %{"error" => "not_found"} =
               call(user, :post, "/api/me/email/confirm", %{token: token}) |> json_response(404)

      call(user, :post, "/api/me/email", %{email: "other.home@example.test", password: password()})

      assert [%UserToken{sent_to: "other.home@example.test"}] = Repo.all(UserToken)
    end

    test "if the address was taken meanwhile: 422, the email stays", %{user: user, token: token} do
      user_fixture(email: @new_email)

      assert %{"errors" => %{"email" => ["has already been taken"]}} =
               call(user, :post, "/api/me/email/confirm", %{token: token}) |> json_response(422)

      assert Repo.get!(User, user.id).email == user.email
    end

    test "links sent to the old address (password reset) stop working", %{
      user: user,
      token: token
    } do
      MlAccounts.request_password_reset(user.email)
      assert_received {:email, %{text_body: body}}
      [_, reset] = Regex.run(~r{/reset-password/([A-Za-z0-9_-]+)\n}, body)

      assert call(user, :post, "/api/me/email/confirm", %{token: token}) |> json_response(200)
      refute MlAccounts.password_reset_valid?(reset)
    end
  end
end
