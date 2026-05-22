// CleaningSelection hook
//
// On mouseup inside the article pane, compute the selection's codepoint
// offsets relative to the source text and push them to the LiveView as
// {start, stop}. Zero-width selections and selections crossing outside
// the pane are ignored. Disabled when the pane carries data-read-only="true".

const Hook = {
  mounted() {
    this.handler = () => this.onMouseUp()
    this.el.addEventListener("mouseup", this.handler)
  },

  destroyed() {
    this.el.removeEventListener("mouseup", this.handler)
  },

  onMouseUp() {
    if (this.el.dataset.readOnly === "true") return

    const sel = window.getSelection()
    if (!sel || sel.isCollapsed) return

    const range = sel.getRangeAt(0)
    if (!this.el.contains(range.startContainer) || !this.el.contains(range.endContainer)) return

    const start = this.offsetIn(range.startContainer, range.startOffset)
    const end = this.offsetIn(range.endContainer, range.endOffset)
    if (start == null || end == null) return

    const lo = Math.min(start, end)
    const hi = Math.max(start, end)
    if (lo === hi) return

    this.pushEvent("add_span", { start: lo, stop: hi })
    sel.removeAllRanges()
  },

  // Compute the codepoint offset of (node, offset) relative to the start of
  // this.el. Uses Range.toString() to extract the text between the two
  // boundaries, then counts codepoints with the spread operator.
  // This handles both text-node offsets and element-node child-index offsets
  // uniformly. Returns null if node is not contained within this.el.
  offsetIn(node, offset) {
    if (!this.el.contains(node)) return null
    const range = document.createRange()
    range.setStart(this.el, 0)
    range.setEnd(node, offset)
    return [...range.toString()].length
  }
}

export default Hook
