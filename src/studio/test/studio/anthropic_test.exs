defmodule MlStudio.AnthropicTest do
  # Global configuration (provider, key): not async. No network: Req.Test stubs MlStudio.AI.Anthropic.
  use MlStudioWeb.ConnCase, async: false
  alias MlStudio.AI
  alias MlStudio.AI.{Anthropic, Generation, GenerationWorker, SettleWorker}
  alias MlStudio.Projects.Lesson

  @config [
    api_key: "sk-ant-test-key",
    model: "claude-fable-5-2",
    effort: "high",
    max_tokens: 16_000,
    receive_timeout: 1_000
  ]
  @outline %{
    "modules" => [
      %{
        "title" => "Moonlight",
        "lessons" => [
          %{"title" => "A seed", "kind" => "story", "summary" => "Why plants need light."}
        ]
      }
    ]
  }

  setup %{conn: conn} do
    put_studio_env(:ai_provider, "anthropic")
    put_studio_env(:anthropic, @config)
    owner = uuid()
    project = project_fixture(owner, %{"title" => "Hidden project title"})
    story = Repo.get_by!(Lesson, project_id: project.id, kind: "story")

    {:ok, _} =
      MlStudio.Projects.update_lesson(owner, project.id, story.id, %{
        "lock_version" => story.lock_version,
        "body" => "SECRET-DRAFT-MARKER"
      })

    stub_services(credit_routes())
    {:ok, owner: owner, project: project, me: as_user(conn, owner)}
  end

  defp reply(conn, status \\ 200, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp message(json, stop \\ "end_turn"),
    do: %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-fable-5-2",
      "content" => [
        %{"type" => "thinking", "thinking" => "", "signature" => "sig"},
        %{"type" => "text", "text" => Jason.encode!(json)}
      ],
      "stop_reason" => stop
    }

  # Stubs the Messages API and sends every request (headers + JSON body) to the test process.
  defp stub_anthropic(fun) do
    test = self()

    Req.Test.stub(Anthropic, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:anthropic, Map.new(conn.req_headers), Jason.decode!(raw)})
      fun.(conn)
    end)
  end

  defp run_outline(me, project) do
    %{"generation" => %{"id" => id}} =
      me
      |> post("/api/projects/#{project.id}/generations", %{
        "kind" => "outline",
        "brief" => "Plan a course about moon gardens",
        "confirm_cost" => 2
      })
      |> json_response(202)

    {id, perform_job(GenerationWorker, %{generation_id: id})}
  end

  test "success: Messages API request shape, structured output, credits consumed", %{
    me: me,
    project: p
  } do
    stub_anthropic(&reply(&1, message(@outline)))
    {id, :ok} = run_outline(me, p)

    assert_received {:anthropic, headers, body}
    assert headers["x-api-key"] == "sk-ant-test-key"
    assert headers["anthropic-version"] == "2026-10-21"
    assert headers["anthropic-beta"] == "server-side-fallback-2026-07-01"

    assert %{
             "model" => "claude-fable-5-2",
             "max_tokens" => 16_000,
             "fallbacks" => "default",
             "system" => system,
             "messages" => [%{"role" => "user", "content" => content}],
             "output_config" => %{
               "effort" => "high",
               "format" => %{
                 "type" => "json_schema",
                 "schema" => %{"type" => "object", "additionalProperties" => false}
               }
             }
           } = body

    # adaptive thinking is always on for this model; sampling parameters are not accepted
    refute Map.has_key?(body, "thinking")
    refute Map.has_key?(body, "temperature")
    assert system =~ "GroveScript"
    assert content =~ "Plan a course about moon gardens"

    assert %Generation{
             status: "succeeded",
             provider: "anthropic",
             model: "claude-fable-5-2",
             result: %{"modules" => [%{"title" => "Moonlight"}]}
           } =
             Repo.get!(Generation, id)

    :ok = perform_job(SettleWorker, %{generation_id: id})
    assert_received {:service, %{path: "/api/internal/credits/consume"}}
  end

  test "CONSENT: without it only the brief of this generation leaves the server", %{
    conn: conn,
    me: me,
    owner: owner,
    project: p
  } do
    stub_anthropic(&reply(&1, message(@outline)))

    {_id, :ok} = run_outline(me, p)
    assert_received {:anthropic, _headers, %{"messages" => [%{"content" => content}]}}
    assert content =~ "Plan a course about moon gardens"
    refute content =~ "Hidden project title"
    refute content =~ "SECRET-DRAFT-MARKER"
    refute content =~ "Seeds of Moonlight"

    # an editor who consents is not enough: the owner's drafts stay private
    editor = uuid()

    Repo.insert!(%MlStudio.Projects.Collaborator{
      project_id: p.id,
      user_id: editor,
      username: "ines_petit",
      role: "editor",
      invited_by: owner
    })

    {:ok, true} = AI.set_consent(editor, %{"share_drafts_with_ai" => true})
    {_id, :ok} = run_outline(as_user(conn, editor), p)
    assert_received {:anthropic, _headers, %{"messages" => [%{"content" => content}]}}
    refute content =~ "Hidden project title"

    # requester and owner both agreed: the project context is added
    {:ok, true} = AI.set_consent(owner, %{"share_drafts_with_ai" => true})
    {_id, :ok} = run_outline(me, p)
    assert_received {:anthropic, _headers, %{"messages" => [%{"content" => content}]}}
    assert content =~ "Hidden project title"
    assert content =~ "Seeds of Moonlight"
  end

  test "errors: retryable statuses retried then final, rejections final, credits released", %{
    me: me,
    project: p
  } do
    stub_anthropic(
      &reply(&1, 529, %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      })
    )

    {id, result} = run_outline(me, p)
    assert {:error, :overloaded} = result

    assert %Generation{status: "pending", error: "overloaded", credits: "reserved"} =
             Repo.get!(Generation, id)

    # last attempt: final failure, credits released
    assert :ok = perform_job(GenerationWorker, %{generation_id: id}, attempt: 3)
    assert %Generation{status: "failed", error: "overloaded"} = Repo.get!(Generation, id)
    :ok = perform_job(SettleWorker, %{generation_id: id})
    assert_received {:service, %{path: "/api/internal/credits/release"}}

    for {response, error} <- [
          {&reply(&1, 400, %{"type" => "error", "error" => %{"type" => "invalid_request_error"}}),
           "provider_rejected"},
          {&reply(&1, 401, %{"type" => "error", "error" => %{"type" => "authentication_error"}}),
           "provider_auth"},
          {&reply(&1, message(%{}, "refusal")), "refused"},
          {&reply(&1, message(@outline, "max_tokens")), "truncated"},
          {&reply(&1, message(%{"modules" => []})), "invalid_output"}
        ] do
      stub_anthropic(response)
      {id, :ok} = run_outline(me, p)
      assert %Generation{status: "failed", error: ^error} = Repo.get!(Generation, id)
    end

    stub_anthropic(&Req.Test.transport_error(&1, :timeout))
    {id, {:error, :timeout}} = run_outline(me, p)
    assert %Generation{status: "pending", error: "timeout"} = Repo.get!(Generation, id)
  end

  test "without ANTHROPIC_API_KEY: explicit refusal, never a simulation", %{me: me, project: p} do
    put_studio_env(:anthropic, Keyword.put(@config, :api_key, nil))

    assert {:error, :not_configured} =
             Anthropic.generate(%{kind: "outline", brief: "x", lesson_kind: nil, context: nil})

    assert %{"provider" => "anthropic", "configured" => false, "demo" => false} =
             me |> get("/api/ai") |> json_response(200)

    assert %{
             "error" => "ai_not_configured",
             "message" => "the AI provider is not configured" <> _
           } =
             me
             |> post("/api/projects/#{p.id}/generations", %{
               "kind" => "outline",
               "brief" => "x",
               "confirm_cost" => 2
             })
             |> json_response(503)

    refute_received {:service, %{path: "/api/internal/credits/reserve"}}
  end

  test "image generation is not available with the real provider", %{me: me, project: p} do
    assert %{
             "error" => "image_generation_unavailable",
             "message" => "image generation is not available with the configured provider"
           } =
             me
             |> post("/api/projects/#{p.id}/generations", %{
               "kind" => "image",
               "brief" => "A leaf",
               "confirm_cost" => 12
             })
             |> json_response(422)

    assert {:error, :image_generation_unavailable} =
             Anthropic.generate_image(%{
               kind: "image",
               brief: "x",
               lesson_kind: nil,
               context: nil
             })
  end

  test "provider selection: explicit, by key, never DEMO by default in production" do
    put_studio_env(:ai_provider, nil)
    assert AI.provider() == Anthropic
    put_studio_env(:anthropic, Keyword.put(@config, :api_key, nil))
    assert AI.provider() == MlStudio.AI.Deterministic
    put_studio_env(:env, :prod)
    assert AI.provider() == Anthropic
    put_studio_env(:ai_provider, "demo")
    assert AI.provider() == MlStudio.AI.Deterministic
  end
end
