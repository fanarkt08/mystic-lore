defmodule MysticWeb.Community.FormLive do
  @moduledoc "New discussion form, and edition by its author during the first 30 minutes."
  use MysticWeb, :live_view
  import MysticWeb.CommunityComponents

  @fields [:category, :title, :body]

  @impl true
  def mount(params, _session, socket), do: {:ok, init(socket, socket.assigns.live_action, params)}

  defp init(socket, :new, _params) do
    categories =
      case Api.get(socket, :community, "/api/categories") do
        {:ok, %{"categories" => list}} when is_list(list) -> Enum.filter(list, & &1["can_post"])
        _ -> :unavailable
      end

    assign(socket,
      page_title: gettext("New discussion"),
      discussion: nil,
      categories: categories,
      form: discussion_form(%{"category" => "", "title" => "", "body" => ""})
    )
  end

  defp init(socket, :edit, %{"slug" => slug}) do
    case Api.get(socket, :community, "/api/discussions/:slug", path_params: [slug: slug]) do
      {:ok, %{"discussion" => %{"can_edit" => true} = discussion}} ->
        assign(socket,
          page_title: gettext("Edit discussion"),
          discussion: discussion,
          categories: [],
          form: discussion_form(Map.take(discussion, ["title", "body"]))
        )

      {:ok, %{"discussion" => %{}}} ->
        socket
        |> put_flash(
          :error,
          gettext(
            "This discussion can't be edited: only its author can, during the first 30 minutes."
          )
        )
        |> push_navigate(to: ~p"/community/discussions/#{slug}")

      {:error, {:http, 404, _}} ->
        raise MysticWeb.NotFoundError

      error ->
        socket
        |> put_flash(:error, community_error(error))
        |> push_navigate(to: ~p"/community")
    end
  end

  defp discussion_form(params, errors \\ []), do: to_form(params, as: :discussion, errors: errors)

  @impl true
  def handle_event("save", %{"discussion" => params}, socket) do
    params = Map.take(params, ["category", "title", "body"])

    result =
      case socket.assigns.discussion do
        nil ->
          Api.post(socket, :community, "/api/discussions", json: params)

        discussion ->
          Api.patch(socket, :community, "/api/discussions/:slug",
            path_params: [slug: discussion["slug"]],
            json: Map.delete(params, "category")
          )
      end

    case result do
      {:ok, %{"discussion" => %{"slug" => slug}}} ->
        message =
          if socket.assigns.discussion,
            do: gettext("Changes saved."),
            else: gettext("Discussion published.")

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/community/discussions/#{slug}")}

      {:error, {:http, 422, _}} = error ->
        {:noreply, assign(socket, form: discussion_form(params, Api.form_errors(error, @fields)))}

      error ->
        {:noreply,
         socket
         |> assign(form: discussion_form(params))
         |> put_flash(:error, community_error(error))}
    end
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:community}
    >
      <div class="mx-auto max-w-3xl space-y-6">
        <.link
          navigate={
            if @discussion,
              do: ~p"/community/discussions/#{@discussion["slug"]}",
              else: ~p"/community"
          }
          class="link text-sm"
        >
          ← {if @discussion, do: gettext("Back to the discussion"), else: gettext("Community")}
        </.link>
        <.page_header title={@page_title}>
          {gettext("Be kind and specific: a clear title helps others find and answer you.")}
        </.page_header>

        <.notice :if={@categories == :unavailable} id="categories-unavailable" kind="warning">
          {gettext("The forum can't be reached right now. Please try again in a moment.")}
        </.notice>

        <.form
          :if={@categories != :unavailable}
          for={@form}
          id="discussion-form"
          phx-submit="save"
          class="card space-y-5"
        >
          <.input
            :if={!@discussion}
            field={@form[:category]}
            type="select"
            label={gettext("Category")}
            prompt={gettext("Choose a category")}
            options={Enum.map(@categories, &{category_name(&1), &1["slug"]})}
            required
          />
          <.input
            field={@form[:title]}
            type="text"
            label={gettext("Title")}
            maxlength="140"
            required
          />
          <.input
            field={@form[:body]}
            type="textarea"
            rows="10"
            maxlength="10000"
            label={gettext("Message")}
            hint={
              gettext(
                "Plain text: HTML isn't interpreted, links starting with http:// or https:// become clickable."
              )
            }
            required
          />
          <div class="flex flex-wrap gap-2">
            <.button type="submit" id="save-discussion" phx-disable-with={gettext("Saving…")}>
              {if @discussion, do: gettext("Save changes"), else: gettext("Publish")}
            </.button>
            <.button
              navigate={
                if @discussion,
                  do: ~p"/community/discussions/#{@discussion["slug"]}",
                  else: ~p"/community"
              }
              variant="ghost"
            >
              {gettext("Cancel")}
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
