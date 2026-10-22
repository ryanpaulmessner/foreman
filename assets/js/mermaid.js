import mermaid from "../vendor/mermaid.min.js"

// Mermaid has global configuration. Keep each theme selection and render together.
let queue = Promise.resolve()
let sequence = 0

export const Mermaid = {
  mounted() {
    this.source = this.el.querySelector("pre").textContent
    this.generation = 0
    this.renderDiagram = () => {
      const generation = ++this.generation
      const theme = document.documentElement.dataset.theme === "dark" ? "dark" : "default"
      queue = queue.then(async () => {
        if (!this.el.isConnected || generation !== this.generation) return
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: "strict",
          theme,
          suppressErrorRendering: true,
          htmlLabels: false,
          flowchart: {htmlLabels: false},
          dompurifyConfig: {FORBID_TAGS: ["style", "img", "image"]},
          secure: ["secure", "securityLevel", "startOnLoad", "suppressErrorRendering", "maxTextSize", "maxEdges", "theme", "htmlLabels", "flowchart", "dompurifyConfig"],
        })
        const target = document.createElement("div")
        this.el.append(target)
        try {
          const {svg} = await mermaid.render(`mermaid-svg-${++sequence}`, this.source, target)
          if (this.el.isConnected && generation === this.generation) {
            target.innerHTML = svg
            const diagram = target.querySelector("svg")
            if (diagram?.viewBox.baseVal.width) {
              diagram.style.width = `${diagram.viewBox.baseVal.width}px`
              diagram.style.maxWidth = "none"
              diagram.style.height = "auto"
            }
            this.el.replaceChildren(target)
          } else target.remove()
        } catch (_) {
          target.remove()
          if (!this.el.isConnected || generation !== this.generation) return
          const error = document.createElement("p")
          error.textContent = "Cannot draw diagram. Check the source."
          error.setAttribute("role", "status")
          const source = document.createElement("pre")
          source.textContent = this.source
          this.el.replaceChildren(error, source)
        }
      }).catch(() => {})
    }
    this.observer = new MutationObserver(this.renderDiagram)
    this.observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
    this.renderDiagram()
  },
  destroyed() {
    ++this.generation
    this.observer.disconnect()
  },
}
