defmodule MysticWeb.AuthHTML do
  @moduledoc "Guest pages: login, sign-up, « check your email », e-mail confirmation."
  use MysticWeb, :html

  embed_templates "auth_html/*"

  @doc "Two-column guest shell: form card + placeholder art (desktop)."
  attr :flash, :map, required: true
  attr :title, :string, required: true
  attr :eyebrow, :string, required: true
  slot :inner_block, required: true
  slot :lead

  def auth_shell(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto grid w-full max-w-5xl gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <section class="card space-y-6 md:p-8">
          <div class="space-y-2">
            <p class="eyebrow">{@eyebrow}</p>
            <h1 class="text-4xl md:text-5xl">{@title}</h1>
            <p :if={@lead != []} class="text-muted">{render_slot(@lead)}</p>
          </div>
          {render_slot(@inner_block)}
        </section>
        <.art cover="hero" class="hidden min-h-[30rem] rounded-panel lg:block" />
      </div>
    </Layouts.app>
    """
  end

  @doc "Inline form posting to `/confirm` to resend the confirmation e-mail."
  attr :email, :string, default: nil
  attr :id, :string, required: true
  attr :label, :string, required: true

  def resend_form(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/confirm"} id={@id} class="space-y-3">
      <input :if={@email} type="hidden" name="email" value={@email} />
      <.input
        :if={!@email}
        id={"#{@id}-email"}
        name="email"
        value=""
        type="email"
        label={gettext("Email")}
        autocomplete="email"
        required
      />
      <.button type="submit" variant="secondary">{@label}</.button>
    </.form>
    """
  end

  def mailbox_url, do: MlShared.Client.base_url(:accounts) <> "/dev/mailbox"
end
