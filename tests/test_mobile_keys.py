#!/usr/bin/env python3
"""Unit tests for the mobile key bar and the build step that bakes it in.

The key bar is the only part of the add-on that runs in the user's browser, so
none of the shell or container tests reach it. What these cover is the seam that
can break silently: build-index.py recovering ttyd's client out of the ttyd
binary. If a ttyd release changes that embedding, the build MUST fail rather
than ship an image whose only symptom is that phones cannot type.
"""

import gzip
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WEB = os.path.join(ROOT, "claude-terminal", "web")
BUILDER = os.path.join(WEB, "build-index.py")
SCRIPT = os.path.join(WEB, "mobile-keys.js")
MARKER = "claude-terminal-mobile-keys"

TTYD_PAGE = (
    "<!DOCTYPE html><html lang=\"en\"><head><title>ttyd - Terminal</title>"
    "</head><body><script>/* xterm bundle */</script></body></html>"
)


def fake_ttyd(page=TTYD_PAGE, prefix=b"\x7fELF fake binary padding"):
    """A stand-in for the ttyd binary: arbitrary bytes with a gzipped page in it."""
    handle = tempfile.NamedTemporaryFile(suffix="-ttyd", delete=False)
    handle.write(prefix)
    if page is not None:
        handle.write(gzip.compress(page.encode("utf-8")))
    handle.write(b"trailing junk")
    handle.close()
    return handle.name


def run_builder(binary, output):
    return subprocess.run(
        [sys.executable, BUILDER],
        env=dict(os.environ, TTYD_BINARY=binary, MOBILE_INDEX_OUTPUT=output),
        capture_output=True,
        text=True,
    )


class TestBuildIndex(unittest.TestCase):
    def setUp(self):
        self.output = tempfile.NamedTemporaryFile(suffix=".html", delete=False).name
        self.binaries = []

    def tearDown(self):
        for path in self.binaries + [self.output]:
            try:
                os.unlink(path)
            except OSError:
                pass

    def binary(self, **kwargs):
        path = fake_ttyd(**kwargs)
        self.binaries.append(path)
        return path

    def test_injects_key_bar_into_ttyds_own_page(self):
        result = run_builder(self.binary(), self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.output, encoding="utf-8") as handle:
            page = handle.read()
        self.assertIn(MARKER, page)
        # ttyd's client has to survive intact: this is an append, not a rewrite.
        # An index.html holding only our script is a blank terminal for everyone.
        self.assertIn("/* xterm bundle */", page)
        self.assertTrue(page.startswith("<!DOCTYPE html"))
        # ...and the script must land inside the document, before </body>
        self.assertLess(page.index(MARKER), page.index("</body>"))

    def test_fails_when_ttyd_embeds_no_html(self):
        """A ttyd that stores its client differently must break the build."""
        result = run_builder(self.binary(page=None), self.output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no embedded index.html", result.stderr)

    def test_fails_rather_than_guess_between_two_pages(self):
        path = self.binary()
        with open(path, "ab") as handle:
            handle.write(gzip.compress(b"<!DOCTYPE html><html>another</html>"))
        result = run_builder(path, self.output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to guess", result.stderr)

    def test_fails_on_unreadable_binary(self):
        result = run_builder(os.path.join(ROOT, "does-not-exist"), self.output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot read", result.stderr)

    def test_finds_the_page_wherever_it_sits(self):
        """Offset-independence is what survives a ttyd upgrade."""
        result = run_builder(self.binary(prefix=b"\x00" * 5000), self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.output, encoding="utf-8") as handle:
            self.assertIn(MARKER, handle.read())


class TestMobileKeysScript(unittest.TestCase):
    def setUp(self):
        with open(SCRIPT, encoding="utf-8") as handle:
            self.source = handle.read()

    def test_carries_the_marker_every_other_check_greps_for(self):
        self.assertIn(MARKER, self.source)

    def test_can_be_inlined_in_a_script_tag(self):
        # A literal </script would close the tag early and spill the rest of the
        # file into the page as visible text.
        self.assertNotIn("</script", self.source.lower())

    def test_is_gated_on_a_coarse_pointer(self):
        """Desktop users must see no change at all."""
        self.assertIn("(pointer: coarse)", self.source)

    def test_drives_xterm_through_the_real_keyboard_path(self):
        # Dispatching at the helper textarea is what makes xterm.js -- not this
        # add-on -- choose the bytes, which is the only reason application
        # cursor key mode (tmux, Claude Code's UI) works without tracking it.
        self.assertIn("xterm-helper-textarea", self.source)
        self.assertIn("KeyboardEvent", self.source)

    def test_sends_the_keys_a_software_keyboard_lacks(self):
        for key_code in ("27", "9", "37", "38", "39", "40"):
            self.assertIn("keyCode: " + key_code, self.source)

    def test_sends_the_characters_a_software_keyboard_buries(self):
        """Slash starts every Claude Code command; pipe is missing outright from
        some software keyboards."""
        self.assertIn("char: '/'", self.source)
        self.assertIn("char: '|'", self.source)

    def test_characters_bypass_the_synthetic_key_path(self):
        """A printable character has one encoding in every terminal mode.

        The keyboard path exists for the cursor keys, whose bytes depend on
        DECCKM; routing a plain character through it would mean xterm.js has to
        reconstruct the character from a synthesised keypress for no benefit.
        """
        self.assertIn("if (spec.char)", self.source)

    def test_paste_is_hidden_when_the_clipboard_is_unreachable(self):
        """Home Assistant is commonly reached over plain http on a LAN, where
        the clipboard API does not exist. A button that always fails on tap is
        worse than no button."""
        self.assertIn("clipboardAvailable", self.source)
        self.assertIn("spec.paste && !clipboardAvailable()", self.source)

    def test_paste_uses_bracketed_paste_when_available(self):
        """Without bracketed paste a multi-line paste into Claude Code submits
        at the first newline and the rest lands in whatever comes next."""
        self.assertIn("term.paste", self.source)

    def test_positions_itself_against_the_visual_viewport(self):
        # position:fixed anchors to the layout viewport, which iOS does not
        # shrink for the keyboard -- so without this the bar hides behind it.
        self.assertIn("visualViewport", self.source)


class TestWiring(unittest.TestCase):
    """The three places that have to agree for the bar to reach a browser."""

    def read(self, *parts):
        with open(os.path.join(ROOT, *parts), encoding="utf-8") as handle:
            return handle.read()

    def test_dockerfile_builds_and_verifies_the_page(self):
        dockerfile = self.read("claude-terminal", "Dockerfile")
        self.assertIn("COPY web/ /opt/web/", dockerfile)
        self.assertIn("build-index.py", dockerfile)
        self.assertIn(MARKER, dockerfile)

    def test_run_sh_serves_it_but_survives_without_it(self):
        run_sh = self.read("claude-terminal", "run.sh")
        self.assertIn("--index /opt/web/index.html", run_sh)
        # Guarded, not assumed: --index at a file ttyd cannot read makes ttyd
        # exit, which is a dead add-on for everyone, not just phone users.
        self.assertIn("[ -s /opt/web/index.html ]", run_sh)

    def test_smoke_test_asserts_the_bar_shipped(self):
        self.assertIn(MARKER, self.read("ci", "smoke.sh"))


if __name__ == "__main__":
    unittest.main()
