#!/usr/bin/env python3
"""Bake the mobile key bar into ttyd's own web client, at image build time.

ttyd has no plugin surface: it compiles its entire front end -- xterm.js, its
addons, the CSS, the favicon -- into a single index.html and embeds that,
gzipped, in the binary. What it does offer is `--index`, which serves a file
from disk in its place.

So the shipped page is ttyd's own, recovered from the binary that will serve it
and with one <script> appended. That ordering is the point: extracting from the
installed binary means the client always matches the ttyd being run, and
appending means a ttyd upgrade brings its new client along with no diff to
resolve here. Authoring a replacement client instead would pin us to whatever
xterm.js version was current the day it was written.

Failure is fatal by design. A silent skip would produce an image that boots,
serves a terminal, and is simply unusable from a phone -- the exact bug this
fixes, reintroduced invisibly. Same reasoning as the Dockerfile's ldd guard.
"""

import os
import sys
import zlib

TTYD_BINARY = os.environ.get("TTYD_BINARY", "/usr/bin/ttyd")
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "mobile-keys.js")
OUTPUT = os.environ.get("MOBILE_INDEX_OUTPUT", os.path.join(HERE, "index.html"))
MARKER = "claude-terminal-mobile-keys"
GZIP_MAGIC = b"\x1f\x8b\x08"


def fail(message):
    sys.stderr.write("FATAL: %s\n" % message)
    sys.exit(1)


def extract_index(binary_path):
    """Return the index.html embedded in a ttyd binary.

    Every gzip stream in the binary is tried and the ones that decompress to
    HTML are kept. Matching on the decompressed content rather than on an
    offset is what makes this survive a ttyd rebuild: the offset moves with
    every release, the payload does not stop being HTML.
    """
    try:
        with open(binary_path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        fail("cannot read %s: %s" % (binary_path, error))

    candidates = []
    offset = data.find(GZIP_MAGIC)
    while offset >= 0:
        try:
            decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
            payload = decompressor.decompress(data[offset:])
        except zlib.error:
            payload = b""
        if payload.lstrip()[:15].lower().startswith(b"<!doctype html"):
            candidates.append(payload)
        offset = data.find(GZIP_MAGIC, offset + 1)

    if not candidates:
        fail(
            "no embedded index.html found in %s. ttyd changed how it stores its "
            "web client (a different compression, or an external asset); this "
            "script has to be taught the new layout before the image can ship."
            % binary_path
        )
    if len(candidates) > 1:
        fail(
            "%d HTML documents found in %s; refusing to guess which one is the "
            "terminal page." % (len(candidates), binary_path)
        )
    return candidates[0].decode("utf-8")


def main():
    index = extract_index(TTYD_BINARY)

    try:
        with open(SCRIPT, "r", encoding="utf-8") as handle:
            script = handle.read()
    except OSError as error:
        fail("cannot read %s: %s" % (SCRIPT, error))

    if MARKER not in script:
        fail("%s does not carry the '%s' marker the smoke test asserts on" % (SCRIPT, MARKER))
    # An unescaped "</script>" anywhere in the source would terminate the tag
    # early and dump the rest of the file into the page as text.
    if "</script" in script.lower():
        fail("%s contains a literal '</script' and cannot be inlined" % SCRIPT)

    needle = "</body>"
    if needle not in index:
        fail("ttyd's index.html has no </body> to append to")

    injected = index.replace(needle, "<script>\n%s\n</script>%s" % (script, needle), 1)

    if MARKER not in injected or len(injected) <= len(index):
        fail("injection produced no change")

    try:
        with open(OUTPUT, "w", encoding="utf-8") as handle:
            handle.write(injected)
    except OSError as error:
        fail("cannot write %s: %s" % (OUTPUT, error))

    sys.stdout.write(
        "mobile key bar baked into %s (%d bytes, ttyd client %d bytes)\n"
        % (OUTPUT, len(injected), len(index))
    )


if __name__ == "__main__":
    main()
