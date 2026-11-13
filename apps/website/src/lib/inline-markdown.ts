// Inline markdown of a changelog bullet (bold, inline code, links) to HTML.
// All text is escaped, and only http(s) and site-relative links become
// anchors, so the output is safe for `set:html`.

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (ch) => ESCAPES[ch]);
}

export function renderInlineMarkdown(text: string): string {
  const pattern = /\*\*([^*]+)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)/g;
  let html = "";
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    html += escapeHtml(text.slice(last, match.index));
    const [whole, bold, code, label, href] = match;
    if (bold !== undefined) {
      // A bold lead can itself wrap inline code.
      html += `<strong>${renderInlineMarkdown(bold)}</strong>`;
    } else if (code !== undefined) {
      html += `<code>${escapeHtml(code)}</code>`;
    } else if (/^(https?:\/\/|\/)/.test(href)) {
      html += `<a href="${escapeHtml(href)}" target="_blank" rel="noreferrer">${escapeHtml(label)}</a>`;
    } else {
      html += escapeHtml(whole);
    }
    last = match.index + whole.length;
  }
  return html + escapeHtml(text.slice(last));
}
