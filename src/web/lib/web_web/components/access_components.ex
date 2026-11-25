defmodule MysticWeb.AccessComponents do
  @moduledoc """
  Themed states of an access that ended or a link that no longer works, each with the next action to take.
  """
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  import MysticWeb.CoreComponents, only: [icon: 1]

  @doc "Renders an explicit state with an icon, a title, a text and the next actions."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, default: "hero-clock"
  attr :tone, :string, default: "warning", values: ~w(warning danger info reward)
  attr :heading, :string, default: "h2", values: ~w(h1 h2 h3)
  attr :live, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def access_state(assigns) do
    ~H"""
    <section
      id={@id}
      class={["access-state", "access-state-#{@tone}", @class]}
      aria-labelledby={"#{@id}-title"}
      role={@live && "status"}
      aria-live={@live && "polite"}
    >
      <span class="access-state-icon" aria-hidden="true"><.icon name={@icon} class="size-6" /></span>
      <div class="min-w-0 flex-1 space-y-2">
        <.dynamic_tag tag_name={@heading} id={"#{@id}-title"} class="access-state-title">
          {@title}
        </.dynamic_tag>
        <div :if={@inner_block != []} class="access-state-text">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="flex flex-wrap gap-2 pt-1">{render_slot(@actions)}</div>
      </div>
    </section>
    """
  end

  @doc """
  When a paid access ended, from billing's entitlements: `{:ended, iso_date | nil}` (date only when billing gives
  a past period end), or `:none` (never subscribed, or still active).
  """
  def access_end(%{"plan" => "free", "status" => status} = entitlements)
      when status in ~w(canceled active past_due) do
    {:ended, past(entitlements["current_period_end"])}
  end

  def access_end(_entitlements), do: :none

  defp past(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> if DateTime.before?(at, DateTime.utc_now()), do: iso
      _ -> nil
    end
  end

  defp past(_), do: nil
end
