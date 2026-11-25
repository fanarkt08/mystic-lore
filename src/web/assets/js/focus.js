// Focus for keyboard users: a panel or a dialog that closes gives the focus back to the control that
// opened it; the studio's confirmation is a real modal dialog (<dialog> opened with showModal(): the page behind is
// inert, the focus stays inside, Escape closes it). No inline script: hooks registered in app.js.

// Last element focused outside a `data-return-focus` panel: the opener, even when the panel focuses itself.
let lastOutside = null
document.addEventListener("focusin", (e) => {
  if (!e.target.closest?.("[data-return-focus]")) lastOutside = e.target
})

// Once LiveView has removed the panel, the focus (lost on <body>) goes back to its opener if it is still there.
function returnFocus(opener) {
  requestAnimationFrame(() => {
    const active = document.activeElement
    if (opener?.isConnected && (!active || active === document.body)) opener.focus()
  })
}

const ReturnFocus = {
  mounted() {
    this.opener = lastOutside
  },
  destroyed() {
    returnFocus(this.opener)
  },
}

// <dialog data-cancel="event"> shown as a modal when mounted (its `open` attribute is ignored by LiveView patches:
// JS.ignore_attributes); Escape (the dialog's `cancel` event) asks the server to close it.
const ModalDialog = {
  mounted() {
    this.opener = lastOutside
    this.el.addEventListener("cancel", (e) => {
      e.preventDefault()
      this.pushEvent(this.el.dataset.cancel, {})
    })
    if (!this.el.matches(":modal")) {
      if (this.el.open) this.el.close()
      this.el.showModal()
    }
  },
  destroyed() {
    returnFocus(this.opener)
  },
}

// After a live form is submitted and the server has answered (LiveView removes `phx-submit-loading` from the form),
// a field in error (aria-invalid, set by <.input>) takes the keyboard focus, the first one: its error is read with it
// (errors shown while typing don't change when the form is sent again, hence the end of the submission is awaited).
// Nothing moves when the person is already typing in another field.
window.addEventListener("submit", (e) => {
  const form = e.target
  if (!(form instanceof HTMLFormElement) || !form.hasAttribute("phx-submit")) return
  // LiveView may lift `phx-submit-loading` before patching the fields (the errors are awaited one more second), and it
  // gives the focus back to the submit button after its patch: the move happens once that is done
  let answered = null
  // the first field in error that a person can see (never a hidden anti-spam field)
  const firstInvalid = () =>
    [...form.querySelectorAll("[aria-invalid=true]")].find(
      (el) => el.getClientRects().length > 0 && !el.closest("[aria-hidden=true], [hidden], .sr-only"),
    )
  const free = () => {
    const active = document.activeElement
    return !active || active === document.body || (form.contains(active) && !active.matches("input, textarea, select"))
  }
  const observer = new MutationObserver(() => {
    if (!form.isConnected) return observer.disconnect()
    if (form.classList.contains("phx-submit-loading")) return
    answered ??= Date.now()
    if (firstInvalid() && free()) {
      observer.disconnect()
      requestAnimationFrame(() =>
        setTimeout(() => {
          const invalid = firstInvalid()
          if (invalid && free()) invalid.focus()
        }, 0),
      )
    } else if (Date.now() - answered > 1000) observer.disconnect()
  })
  observer.observe(form, {subtree: true, childList: true, attributes: true, attributeFilter: ["aria-invalid", "class"]})
  setTimeout(() => observer.disconnect(), 10000)
})
// A form page rendered by a controller (sign-up, login…) with errors: the first field in error has the focus.
if (!document.querySelector("[data-phx-main]")) {
  window.addEventListener("DOMContentLoaded", () =>
    [...document.querySelectorAll("form [aria-invalid=true]")]
      .find((el) => el.getClientRects().length > 0 && !el.closest("[aria-hidden=true], [hidden], .sr-only"))
      ?.focus(),
  )
}

export const FocusHooks = {ReturnFocus, ModalDialog}
