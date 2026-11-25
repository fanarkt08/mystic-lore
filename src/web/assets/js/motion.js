// Reduced motion for scripts: the member's preference (`<html data-motion="reduce">`) or the system setting.
// CSS covers animations and transitions (features/preferences.css); hooks that move things use this helper,
// e.g. `import {reducedMotion, scrollBehavior} from "@/js/motion"` in a colocated hook.
export const reducedMotion = () =>
  document.documentElement.dataset.motion === "reduce" ||
  window.matchMedia("(prefers-reduced-motion: reduce)").matches

// `behavior` for scrollIntoView / scrollTo: never smooth when motion is reduced.
export const scrollBehavior = () => (reducedMotion() ? "auto" : "smooth")
