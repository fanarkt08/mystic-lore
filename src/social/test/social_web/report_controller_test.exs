defmodule MlSocialWeb.ReportControllerTest do
  use MlSocialWeb.ConnCase, async: true
  alias MlSocial.{Message, Repo, Report}

  setup do
    {:ok, a: uuid(), b: uuid(), c: uuid()}
  end

  defp report(user, attrs), do: api(:post, "/api/reports", user, attrs)

  test "signaler un message conserve un instantané (texte, auteur, date)", %{a: a, b: b} do
    conversation = conversation_between(a, b)

    %{"message" => %{"id" => message_id}} =
      api(:post, "/api/conversations/#{conversation.id}/messages", b, %{
        body: "Message déplaisant"
      })
      |> json_response(201)

    assert %{"id" => report_id} =
             report(a, %{
               target_type: "message",
               target_id: message_id,
               reason: "harassment",
               details: "  insistant  "
             })
             |> json_response(201)

    # l'instantané survit à la disparition du message
    message = Repo.get!(Message, message_id)
    Repo.delete!(message)

    assert %Report{
             reporter_id: ^a,
             target_type: "message",
             target_id: ^message_id,
             reason: "harassment",
             details: "insistant",
             message_body: "Message déplaisant",
             message_sender_id: ^b
           } = report = Repo.get!(Report, report_id)

    assert report.message_sent_at == message.inserted_at
  end

  test "signaler un membre ; validation des champs", %{a: a, b: b} do
    assert %{"id" => id} =
             report(a, %{target_type: "user", target_id: b, reason: "spam"}) |> json_response(201)

    assert %Report{target_type: "user", target_id: ^b, message_body: nil} = Repo.get!(Report, id)

    assert %{"error" => "invalid", "errors" => errors} =
             report(a, %{target_type: "post", target_id: "x", reason: "meh"})
             |> json_response(422)

    assert errors |> Map.keys() |> Enum.sort() == ~w(reason target_id target_type)

    # cible non UUID alors que le reste est valide : 422, pas d'erreur d'insertion
    assert %{"errors" => %{"target_id" => ["is invalid"]}} =
             report(a, %{target_type: "user", target_id: "x", reason: "spam"})
             |> json_response(422)

    assert %{"errors" => %{"target_type" => _, "target_id" => _, "reason" => _}} =
             report(a, %{}) |> json_response(422)

    assert %{"errors" => %{"target_id" => ["cannot be yourself"]}} =
             report(a, %{target_type: "user", target_id: a, reason: "other"})
             |> json_response(422)

    assert %{"errors" => %{"details" => ["should be at most 2000 character(s)"]}} =
             report(a, %{
               target_type: "user",
               target_id: b,
               reason: "other",
               details: String.duplicate("x", 2001)
             })
             |> json_response(422)
  end

  test "un message hors de ses conversations n'est pas signalable (même réponse qu'un id inconnu)",
       %{
         a: a,
         b: b,
         c: c
       } do
    conversation = conversation_between(a, b)
    [%{id: message_id}] = insert_messages(conversation, [{b, "privé", 5}])

    for target <- [message_id, uuid()] do
      assert %{"errors" => %{"target_id" => ["is invalid"]}} =
               report(c, %{target_type: "message", target_id: target, reason: "spam"})
               |> json_response(422)
    end

    assert %{"errors" => %{"target_id" => ["cannot be your own message"]}} =
             report(b, %{target_type: "message", target_id: message_id, reason: "spam"})
             |> json_response(422)

    refute Repo.get_by(Report, target_id: message_id)
  end
end
