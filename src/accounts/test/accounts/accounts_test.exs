defmodule MlAccountsTest do
  use MlAccounts.DataCase, async: true
  alias MlAccounts.{LoginFailure, User}

  test "seeds create the 6 demo members with their fixed UUIDs, idempotently" do
    seed = fn -> ExUnit.CaptureIO.capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end) end
    seed.()
    seed.()

    users = User |> Repo.all() |> Enum.sort_by(& &1.id)
    assert length(users) == 6

    for {demo, user} <- Enum.zip(MlShared.Demo.users(), users) do
      assert Map.take(user, [:id, :email, :username, :display_name, :role]) ==
               Map.take(demo, [:id, :email, :username, :display_name, :role])

      assert user.confirmed_at
      assert User.valid_password?(user, MlShared.Demo.password())
    end
  end

  test "the database itself enforces case-insensitive uniqueness of email and username" do
    insert = fn email, username ->
      %User{email: email, username: username, display_name: "x", hashed_password: "x"}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:email)
      |> Ecto.Changeset.unique_constraint(:username)
      |> Repo.insert()
    end

    assert {:ok, _} = insert.("Case@Example.test", "case_user")

    assert {:error, %{errors: [email: {"has already been taken", _}]}} =
             insert.("case@example.TEST", "other_user")

    assert {:error, %{errors: [username: {"has already been taken", _}]}} =
             insert.("other@example.test", "CASE_USER")
  end

  test "the role is constrained by the database" do
    user = user_fixture()

    assert_raise Ecto.ConstraintError, fn ->
      user |> Ecto.Changeset.change(role: "wizard") |> Repo.update()
    end
  end

  test "concurrent wrong attempts cannot get past the lock" do
    user = user_fixture()

    results =
      1..10
      |> Task.async_stream(fn _ -> MlAccounts.login(user.email, "definitely the wrong one") end,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.frequencies(results) == %{
             {:error, :invalid_credentials} => 5,
             {:error, :locked} => 5
           }

    assert Repo.aggregate(LoginFailure, :count) == 5
  end
end
