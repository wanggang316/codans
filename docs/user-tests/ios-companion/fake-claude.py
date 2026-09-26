#!/usr/bin/env python3
# A Claude Code-like session for acceptance screenshots: draws a finished
# turn in the alternate screen, then echoes typed lines into the prompt box.
import os, shutil, signal, sys

ESC = "\x1b"
def sgr(codes, text): return f"{ESC}[{codes}m{text}{ESC}[0m"
ACCENT, DIM, EDGE = "38;2;215;119;87", "38;5;245", "38;5;240"
ADD, DEL = "48;2;34;70;42", "48;2;86;36;36"

def draw(typed=""):
  cols = shutil.get_terminal_size((100, 40)).columns
  cwd = os.getcwd().replace(os.path.expanduser("~"), "~")
  width = 52
  def boxed(plain, styled):
    return sgr(ACCENT, "│") + styled + " " * max(0, width - len(plain)) + sgr(ACCENT, "│")
  lines = [
    sgr(ACCENT, "╭" + "─" * width + "╮"),
    boxed(" ✻ Welcome to Claude Code!", " " + sgr(ACCENT, "✻") + " Welcome to " + sgr("1", "Claude Code") + "!"),
    boxed("", ""),
    boxed("   /help for help, /status for your setup", sgr(DIM, "   /help for help, /status for your setup")),
    boxed(f"   cwd: {cwd[-40:]}", sgr(DIM, f"   cwd: {cwd[-40:]}")),
    sgr(ACCENT, "╰" + "─" * width + "╯"),
    "",
    sgr(DIM, "> ") + "Retry failed checkout requests with backoff",
    "",
    sgr(ACCENT, "⏺") + " I'll wrap the payment call in a retry with jittered backoff.",
    "",
    sgr(ACCENT, "⏺") + " " + sgr("1", "Read") + "(src/checkout/client.ts)",
    "  " + sgr(DIM, "⎿  Read 84 lines"),
    "",
    sgr(ACCENT, "⏺") + " " + sgr("1", "Update") + "(src/checkout/client.ts)",
    "  " + sgr(DIM, "⎿  Updated src/checkout/client.ts with 3 additions and 1 removal"),
    "     " + sgr(DIM, "41") + "   export async function submit(order: Order) {",
    "     " + sgr(DIM, "42") + sgr(DEL, "-    return api.post('/checkout', order)                  "),
    "     " + sgr(DIM, "42") + sgr(ADD, "+    return withRetry(() => api.post('/checkout', order), {"),
    "     " + sgr(DIM, "43") + sgr(ADD, "+      attempts: 3, backoff: 'jittered',                  "),
    "     " + sgr(DIM, "44") + sgr(ADD, "+    })                                                  "),
    "     " + sgr(DIM, "45") + "   }",
    "",
    sgr(ACCENT, "⏺") + " " + sgr("1", "Bash") + "(npm test -- checkout)",
    "  " + sgr(DIM, "⎿  ") + sgr("32", "PASS") + sgr(DIM, " src/checkout/client.test.ts (12 tests)"),
    "",
    sgr(ACCENT, "✢ Checking the idempotency key… ") + sgr(DIM, "(21s · ↑ 1.8k tokens · esc to interrupt)"),
    "",
    sgr(EDGE, "╭" + "─" * (cols - 2) + "╮"),
    sgr(EDGE, "│") + " > " + typed[: cols - 6] + " " * max(0, cols - 5 - len(typed)) + sgr(EDGE, "│"),
    sgr(EDGE, "╰" + "─" * (cols - 2) + "╯"),
    sgr(DIM, "  ⏵⏵ accept edits on (shift+tab to cycle)"),
  ]
  sys.stdout.write(f"{ESC}[?1049h{ESC}[?25l{ESC}[2J{ESC}[H" + "\r\n".join(lines))
  sys.stdout.flush()

typed = ""
signal.signal(signal.SIGWINCH, lambda *_: draw(typed))
draw()
for line in sys.stdin:
  typed = line.rstrip("\n")
  draw(typed)
