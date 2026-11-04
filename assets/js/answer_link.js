export const AnswerLink = {
  mounted() {
    this.button = this.el.querySelector('[data-copy]')
    this.status = this.el.querySelector('[data-copy-status]')
    this.copy = async () => {
      const url = new URL(this.el.dataset.url, window.location.origin).href
      try {
        await navigator.clipboard.writeText(url)
        this.button.title = 'Copied'
        this.button.setAttribute('aria-label', 'Copied')
        this.status.classList.remove('bb-answer-copy-failed')
        this.status.textContent = 'Copied'
        this.el.querySelector('[data-copy-icon]').classList.add('hidden')
        this.el.querySelector('[data-check-icon]').classList.remove('hidden')
        clearTimeout(this.timer)
        this.timer = setTimeout(() => this.reset(), 2000)
      } catch {
        sessionStorage.setItem('answer-copy-failed', this.el.dataset.url)
        window.location.assign(this.el.dataset.url)
      }
    }
    if (sessionStorage.getItem('answer-copy-failed') === this.el.dataset.url) {
      sessionStorage.removeItem('answer-copy-failed')
      this.status.classList.add('bb-answer-copy-failed')
      this.status.textContent = 'Copy failed. Copy the link from the address bar.'
    }
    this.button.addEventListener('click', this.copy)
  },
  reset() {
    this.button.title = 'Copy link'
    this.button.setAttribute('aria-label', 'Copy link')
    this.status.textContent = ''
    this.el.querySelector('[data-copy-icon]').classList.remove('hidden')
    this.el.querySelector('[data-check-icon]').classList.add('hidden')
  },
  destroyed() {
    clearTimeout(this.timer)
    this.button.removeEventListener('click', this.copy)
  }
}
