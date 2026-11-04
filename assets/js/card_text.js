// The card's one text box: Ask, Wrong question and Withdraw are off until it has text.
export default {
  mounted() {
    this.sync = () => {
      const empty = this.el.value.trim() === ""
      this.el.form?.querySelectorAll("[data-needs-text]").forEach(button => { button.disabled = empty })
    }
    this.el.addEventListener("input", this.sync)
    this.sync()
  },
  updated() { this.sync() },
  destroyed() { this.el.removeEventListener("input", this.sync) }
}
