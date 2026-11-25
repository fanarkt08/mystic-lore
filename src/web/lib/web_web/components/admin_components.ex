defmodule MysticWeb.AdminComponents do
  @moduledoc "Building blocks of the administration pages: metric tiles, responsive tables, pagination and tags."
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  use Phoenix.VerifiedRoutes, endpoint: MysticWeb.Endpoint, router: MysticWeb.Router
  import MysticWeb.MysticComponents, only: [tag: 1]

  def role_label("admin"), do: gettext("Admin")
  def role_label("moderator"), do: gettext("Moderator")
  def role_label(_), do: gettext("Member")

  @doc "Role chip (always a word, never colour only)."
  attr :role, :string, required: true

  def role_tag(assigns) do
    ~H"""
    <.tag kind={if @role == "user", do: "neutral", else: "info"}>{role_label(@role)}</.tag>
    """
  end

  @doc "Sanction status chip."
  attr :status, :string, required: true

  def sanction_status(assigns) do
    ~H"""
    <%= case @status do %>
      <% "active" -> %>
        <.tag kind="danger">{gettext("Active")}</.tag>
      <% "expired" -> %>
        <.tag>{gettext("Expired")}</.tag>
      <% _ -> %>
        <.tag kind="success">{gettext("Lifted")}</.tag>
    <% end %>
    """
  end

  def sanction_kind("warning"), do: gettext("Warning")
  def sanction_kind(_), do: gettext("Restriction")

  @doc "Severity chip of an incident."
  attr :severity, :string, required: true

  def severity_tag(assigns) do
    ~H"""
    <.tag kind={if @severity in ~w(high critical), do: "danger", else: "neutral"}>
      {severity_label(@severity)}
    </.tag>
    """
  end

  def severity_label("low"), do: gettext("Low")
  def severity_label("medium"), do: gettext("Medium")
  def severity_label("high"), do: gettext("High")
  def severity_label("critical"), do: gettext("Critical")
  def severity_label(other), do: to_string(other)

  def incident_status_label("open"), do: gettext("Open")
  def incident_status_label("investigating"), do: gettext("Investigating")
  def incident_status_label("resolved"), do: gettext("Resolved")
  def incident_status_label(other), do: to_string(other)

  def reason_label("harassment"), do: gettext("Harassment")
  def reason_label("spam"), do: gettext("Spam")
  def reason_label("inappropriate"), do: gettext("Inappropriate content")
  def reason_label("other"), do: gettext("Other")
  def reason_label(other), do: to_string(other)

  @doc "A member as \"Display name (@username)\"; unknown names stay explicit."
  attr :person, :map, default: nil

  def person(assigns) do
    ~H"""
    <span :if={is_map(@person) and @person["username"]}>
      {MysticWeb.MysticComponents.member_name(@person)}
      <span :if={!MysticWeb.MysticComponents.deleted_member?(@person)} class="text-muted">
        @{@person["username"]}
      </span>
    </span>
    <span :if={!(is_map(@person) and @person["username"])} class="text-muted">
      {gettext("Unknown member")}
    </span>
    """
  end

  @doc "Renders one measured value, or says why there is none (never a made-up number)."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  def metric(assigns) do
    ~H"""
    <div id={@id} class="metric">
      <dt class="text-sm text-muted">{@label}</dt>
      <dd class={["metric-value", not_a_number?(@value) && "metric-missing"]}>
        <%= case @value do %>
          <% :not_measured -> %>
            {gettext("Unavailable — not measured")}
          <% :unavailable -> %>
            {gettext("Temporarily unavailable")}
          <% :admins_only -> %>
            {gettext("Admins only")}
          <% value -> %>
            {value}
        <% end %>
      </dd>
    </div>
    """
  end

  defp not_a_number?(value), do: value in [:not_measured, :unavailable, :admins_only]

  @doc "Previous / next links of a paginated list (`path` builds the URL of a page)."
  attr :page, :map, required: true, doc: "`%{\"page\", \"total_pages\"}`"
  attr :path, :any, required: true
  attr :id, :string, default: "pager"

  def pager(assigns) do
    ~H"""
    <nav
      :if={(@page["total_pages"] || 1) > 1}
      id={@id}
      class="flex items-center justify-between gap-3"
      aria-label={gettext("Pagination")}
    >
      <.link
        :if={@page["page"] > 1}
        patch={@path.(@page["page"] - 1)}
        class="btn btn-secondary"
        rel="prev"
      >
        ← {gettext("Previous")}
      </.link>
      <span class="text-sm text-muted">
        {gettext("Page %{page} of %{total}", page: @page["page"], total: @page["total_pages"])}
      </span>
      <.link
        :if={@page["page"] < @page["total_pages"]}
        patch={@path.(@page["page"] + 1)}
        class="btn btn-secondary"
        rel="next"
      >
        {gettext("Next")} →
      </.link>
    </nav>
    """
  end
end
