defmodule MysticWeb.LegalComponents do
  @moduledoc """
  Building blocks of the provisional legal pages. The operator's identity is never invented: missing
  information is shown as an explicit placeholder.
  """
  use MysticWeb, :html
  alias MysticWeb.Legal

  @doc "Visible on every legal page: provisional, to be validated by a lawyer; version and last update."
  attr :document, :string, default: nil, doc: "nil: the index (all documents)"

  def legal_banner(assigns) do
    ~H"""
    <div id="legal-banner" class="legal-banner" role="note">
      <.icon name="hero-exclamation-triangle" class="size-6 shrink-0" />
      <div class="min-w-0 space-y-1">
        <p class="font-semibold text-ink">
          {gettext("Provisional text, to be validated by a lawyer before any production use.")}
        </p>
        <p class="text-sm">
          {gettext(
            "It describes what this version of MysticLore actually does, but it has not been reviewed by a lawyer and it claims no certified compliance."
          )}
        </p>
        <p :if={@document} id="legal-version" class="text-sm">
          {gettext("Version %{version} · last updated %{date}",
            version: elem(Legal.version(@document), 0),
            date: date(elem(Legal.version(@document), 1))
          )}
        </p>
      </div>
    </div>
    """
  end

  @doc "Information only the operator can give: shown as an explicit gap, never filled with invented data."
  attr :id, :string, required: true
  slot :inner_block, required: true

  def placeholder(assigns) do
    ~H"""
    <span id={@id} class="legal-placeholder">
      <span class="legal-placeholder-tag">{gettext("To be completed by the operator")}</span>
      <span>{render_slot(@inner_block)}</span>
    </span>
    """
  end

  @doc "Who runs the service: every field is a placeholder in this version."
  def operator_identity(assigns) do
    ~H"""
    <dl id="operator-identity" class="legal-identity">
      <div>
        <dt>{gettext("Operator (legal entity)")}</dt>
        <dd>
          <.placeholder id="operator-entity">{gettext("name and legal form")}</.placeholder>
        </dd>
      </div>
      <div>
        <dt>{gettext("Registered address")}</dt>
        <dd>
          <.placeholder id="operator-address">{gettext("postal address")}</.placeholder>
        </dd>
      </div>
      <div>
        <dt>{gettext("Registration")}</dt>
        <dd>
          <.placeholder id="operator-registration">
            {gettext("company register and number, VAT number if any")}
          </.placeholder>
        </dd>
      </div>
      <div>
        <dt>{gettext("Publication director")}</dt>
        <dd>
          <.placeholder id="operator-director">{gettext("name")}</.placeholder>
        </dd>
      </div>
      <div>
        <dt>{gettext("Hosting provider")}</dt>
        <dd>
          <.placeholder id="operator-host">
            {gettext("name, address and contact of the host")}
          </.placeholder>
        </dd>
      </div>
      <div>
        <dt>{gettext("Data protection contact")}</dt>
        <dd>
          <.placeholder id="operator-dpo">
            {gettext("data protection officer or privacy contact (e-mail or postal address)")}
          </.placeholder>
        </dd>
      </div>
    </dl>
    """
  end

  @doc "Links between the documents (the current one is marked)."
  attr :current, :string, default: nil

  def legal_nav(assigns) do
    ~H"""
    <nav id="legal-nav" class="legal-nav" aria-label={gettext("Legal documents")}>
      <ul>
        <li>
          <.link
            navigate={~p"/legal"}
            aria-current={is_nil(@current) && "page"}
            class="legal-nav-link"
          >
            {gettext("Overview")}
          </.link>
        </li>
        <li :for={doc <- Legal.documents()}>
          <.link
            navigate={~p"/legal/#{doc}"}
            id={"legal-nav-#{doc}"}
            aria-current={@current == doc && "page"}
            class="legal-nav-link"
          >
            {Legal.title(doc)}
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  @doc "A numbered section with an anchor."
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def legal_section(assigns) do
    ~H"""
    <section id={@id} class="legal-section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="text-2xl md:text-3xl">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "A table that becomes a list of cards below 768 px (`data-label` on each cell)."
  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :rows, :list, required: true

  slot :col, required: true do
    attr :label, :string, required: true
  end

  def legal_table(assigns) do
    ~H"""
    <table id={@id} class="legal-table">
      <caption class="sr-only">{@caption}</caption>
      <thead>
        <tr>
          <th :for={col <- @col} scope="col">{col.label}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <td :for={col <- @col} data-label={col.label}>{render_slot(col, row)}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
