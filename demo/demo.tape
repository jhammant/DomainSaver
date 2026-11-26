# DomainSaver demo — a faithful Codex version of the original terminal reveal.
#
# Render from the repository root:
#
#   PORKBUN_API_KEY=... PORKBUN_SECRET_KEY=... vhs demo/demo.tape
#
# Output: demo/demo.gif
#
# Requirements:
#   * Codex CLI installed and signed in with a ChatGPT account.
#   * The domain-search skill installed with ./install.sh --target codex.
#   * PORKBUN_API_KEY / PORKBUN_SECRET_KEY exported for the live quote.
#
# Original work by Jon Hammant with Claude:
#   https://github.com/jhammant/DomainSaver
#
# The visible interaction keeps the original check, warning and quote sequence.
# The only functional change is that each operation is requested through the
# $domain-search skill. The hidden helper selects non-interactive execution,
# low reasoning effort and live network access, then removes Markdown markers
# for the original plain-terminal look. None of that is part of the prompt and
# no response is staged.

Output demo/demo.gif

Require codex

Set Shell bash
Set FontSize 18
Set Width 1500
Set Height 480
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0
Set WaitTimeout 180s

# Keep recording-only launch settings off screen. Codex still uses the normal
# ChatGPT login and installed $domain-search skill.
Hide
Type `codex() { command codex exec --ignore-user-config --ephemeral -s danger-full-access -c model_reasoning_effort=low "$@" 2>/dev/null | tr -d '*\140'; }` Enter
Type "clear" Enter
Show

Sleep 800ms

# --- Act 1: what every other tool tells you ------------------------------
Type "# Every domain tool says this name is available." Enter
Sleep 1200ms
Type "codex '$domain-search Check shed.link without a quote'" Enter

# Hide only the model wait; resume on the real registry result.
Sleep 600ms
Hide
Wait+Screen@90s /UNREGISTERED/
Show
Sleep 1800ms

# --- Act 2: the skill refuses to say 'available' ------------------------
Type "" Enter
Type "# UNREGISTERED. Not AVAILABLE. It will not guess." Enter
Sleep 2s
Type "# $7.72 is the TLD list price, not a quote for this name." Enter
Sleep 2500ms

# --- Act 3: the reveal ---------------------------------------------------
Type "clear" Enter
Sleep 500ms
Type "# So ask the registrar what it actually costs." Enter
Sleep 1200ms
Type "codex '$domain-search Quote shed.link'" Enter

Sleep 600ms
Hide
Wait+Screen@90s /819.27/
Show
Sleep 2200ms

Type "" Enter
Type "# $819.27/yr. 106x the list price." Enter
Sleep 2500ms
Type "# Original work: Jon Hammant + Claude" Enter
Sleep 1600ms
Type "# github.com/jhammant/DomainSaver" Enter
Sleep 3s

# ---------------------------------------------------------------------------
# Social exports (LinkedIn wants video, not GIF). Regenerate from demo.gif:
#
#   16:9 — ffmpeg -y -i demo/demo.gif -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
#            -vf "scale=1920:-2:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0x1e1e2c,format=yuv420p" \
#            -c:v libx264 -preset slow -crf 20 -r 30 -c:a aac -b:a 96k -shortest \
#            -movflags +faststart demo/demo-16x9.mp4
#
#   1:1  — same, with scale=1080:-2 and pad=1080:1080
#
# The silent AAC track is deliberate: some platforms mishandle a video stream
# with no audio stream at all. format=yuv420p and even dimensions are required
# for H.264 to play everywhere.
