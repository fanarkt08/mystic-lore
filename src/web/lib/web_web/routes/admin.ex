defmodule MysticWeb.Routes.Admin do
  @moduledoc "Routes of the administration and moderation area, inserted in `MysticWeb.Router`."
  defmacro browser do
    quote do
      get "/admin/audit/export", Admin.AuditExportController, :show
      post "/admin/reports/social/:id/attachment", Admin.AttachmentEvidenceController, :create
    end
  end

  defmacro member do
    quote do
      live "/admin", Admin.OverviewLive
      live "/admin/reports", Admin.ReportsLive, :index
      live "/admin/reports/:source/:id", Admin.ReportsLive, :show
      live "/admin/members", Admin.MembersLive, :index
      live "/admin/members/:id", Admin.MembersLive, :show
      live "/admin/sanctions-appeals", Admin.AppealsLive
      live "/admin/incidents", Admin.IncidentsLive, :index
      live "/admin/incidents/:id", Admin.IncidentsLive, :show
      live "/admin/audit", Admin.AuditLive
      live "/admin/billing", Admin.BillingLive

      # demandes du formulaire de contact : liste, détail audité, réponse, statut, note
      live "/admin/support", Admin.SupportLive, :index
      live "/admin/support/:id", Admin.SupportLive, :show
      live "/account/sanctions", Account.SanctionsLive
    end
  end
end
