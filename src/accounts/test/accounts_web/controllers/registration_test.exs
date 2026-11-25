defmodule MlAccountsWeb.RegistrationTest do
  use MlAccountsWeb.ConnCase, async: true
  import Swoosh.TestAssertions
  alias MlAccounts.ConfirmationToken

  @valid %{
    "email" => " Lea.New@Example.TEST ",
    "username" => "Lea_New",
    "password" => "twelve chars"
  }

  defp register(params), do: build_conn() |> internal() |> post("/api/users", params)

  defp confirm(token),
    do: build_conn() |> internal() |> post("/api/users/confirm", %{token: token})

  defp resend(email),
    do: build_conn() |> internal() |> post("/api/users/resend-confirmation", %{email: email})

  # Jeton extrait du lien reçu par e-mail (adaptateur Swoosh de test).
  defp emailed_token do
    assert_received {:email, email}
    token_in(email)
  end

  defp token_in(%Swoosh.Email{text_body: body}) do
    [_, token] = Regex.run(~r{http://localhost:4000/confirm/([A-Za-z0-9_-]+)\n}, body)
    token
  end

  describe "POST /api/users" do
    test "creates an unconfirmed user and emails a confirmation link" do
      assert %{"user" => user} = register(@valid) |> json_response(201)

      assert %{
               "email" => "lea.new@example.test",
               "username" => "lea_new",
               "display_name" => "lea_new",
               "bio" => nil,
               "confirmed" => false,
               "role" => "user"
             } = user

      assert {:ok, _, 0} = DateTime.from_iso8601(user["inserted_at"])

      assert_received {:email, email}
      assert email.to == [{"lea_new", "lea.new@example.test"}]
      assert email.subject == "Confirm your MysticLore account"
      token = token_in(email)
      assert byte_size(token) == 43
      assert [%ConfirmationToken{token_hash: hash}] = Repo.all(ConfirmationToken)
      assert hash == :crypto.hash(:sha256, token)
    end

    test "keeps the display name and never accepts a role" do
      params = Map.merge(@valid, %{"display_name" => "  Léa Moreau ", "role" => "admin"})

      assert %{"user" => %{"display_name" => "Léa Moreau", "role" => "user"}} =
               register(params) |> json_response(201)
    end

    test "validates the input" do
      params = %{
        "email" => "not an email",
        "username" => "x!",
        "password" => "eleven char",
        "display_name" => String.duplicate("a", 61)
      }

      assert %{"error" => "invalid", "errors" => errors} = register(params) |> json_response(422)
      assert errors["password"] == ["should be at least 12 character(s)"]

      assert %{
               "email" => [_],
               "username" => [_],
               "display_name" => ["should be at most 60 character(s)"]
             } = errors

      assert %{"errors" => errors} = register(%{}) |> json_response(422)

      assert errors == %{
               "email" => ["can't be blank"],
               "username" => ["can't be blank"],
               "password" => ["can't be blank"]
             }

      too_long = Map.put(@valid, "password", String.duplicate("é", 37))

      assert %{"errors" => %{"password" => ["should be at most 72 byte(s)"]}} =
               register(too_long) |> json_response(422)

      refute_email_sent()
    end

    test "email and username are unique, case-insensitively" do
      assert register(@valid) |> json_response(201)
      assert_email_sent()

      same_email = %{@valid | "email" => "LEA.NEW@example.test", "username" => "someone_else"}
      assert %{"errors" => errors} = register(same_email) |> json_response(422)
      assert errors == %{"email" => ["has already been taken"]}

      same_username = %{@valid | "email" => "other@example.test", "username" => "LEA_NEW"}
      assert %{"errors" => errors} = register(same_username) |> json_response(422)
      assert errors == %{"username" => ["has already been taken"]}

      refute_email_sent()
    end
  end

  describe "POST /api/users/confirm" do
    setup do
      register(@valid) |> json_response(201)
      %{token: emailed_token()}
    end

    test "confirms the email once; the token cannot be reused", %{token: token} do
      assert %{"user" => %{"confirmed" => true, "username" => "lea_new"}} =
               confirm(token) |> json_response(200)

      assert %{"error" => "not_found"} = confirm(token) |> json_response(404)
      assert Repo.all(ConfirmationToken) == []
    end

    test "a token expires after 7 days", %{token: token} do
      seven_days_ago = DateTime.add(DateTime.utc_now(:second), -7, :day)
      Repo.update_all(ConfirmationToken, set: [inserted_at: seven_days_ago])
      assert %{"error" => "not_found"} = confirm(token) |> json_response(404)

      Repo.update_all(ConfirmationToken,
        set: [inserted_at: DateTime.add(seven_days_ago, 1, :hour)]
      )

      assert %{"user" => %{"confirmed" => true}} = confirm(token) |> json_response(200)
    end

    test "unknown or missing tokens are not found" do
      assert %{"error" => "not_found"} = confirm("not-a-real-token") |> json_response(404)

      assert %{"error" => "not_found"} =
               build_conn() |> internal() |> post("/api/users/confirm", %{}) |> json_response(404)
    end
  end

  describe "POST /api/users/resend-confirmation" do
    test "always answers 204 but only emails unconfirmed accounts" do
      confirmed = user_fixture()
      unconfirmed = user_fixture(confirmed: false)

      for email <- ["nobody@example.test", confirmed.email, nil] do
        assert resend(email) |> response(204) == ""
      end

      refute_email_sent()

      assert resend(String.upcase(unconfirmed.email)) |> response(204)

      assert %{"user" => %{"id" => id, "confirmed" => true}} =
               emailed_token() |> confirm() |> json_response(200)

      assert id == unconfirmed.id
    end

    test "sends at most 3 confirmation emails per hour" do
      user = user_fixture(confirmed: false)
      for _ <- 1..4, do: assert(resend(user.email) |> response(204))

      for _ <- 1..3, do: assert_received({:email, _})
      refute_received {:email, _}
    end
  end
end
