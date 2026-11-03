// The board's copy field (ForemanWeb.CopyField): "Copied" for 2 s on success;
// when the clipboard fails, the field text is selected so it can be copied by hand.
export const CopyField = {
  mounted() {
    this.onClick = event => {
      if (!event.target.closest("[data-copy-button]")) return
      const field = this.el.querySelector("[data-copy-value]")
      const copied = () => {
        clearTimeout(this.timer)
        this.el.dataset.copied = ""
        this.timer = setTimeout(() => delete this.el.dataset.copied, 2000)
      }
      const failed = () => {
        clearTimeout(this.timer)
        delete this.el.dataset.copied
        field.focus()
        field.select()
      }
      if (!navigator.clipboard?.writeText) return failed()
      navigator.clipboard.writeText(field.value).then(copied, failed)
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("click", this.onClick)
  },
}
