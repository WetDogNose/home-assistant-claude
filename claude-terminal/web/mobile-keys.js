/*
 * claude-terminal-mobile-keys
 *
 * A touch key bar for the keys an on-screen keyboard does not have.
 *
 * iOS (and most Android) software keyboards ship no cursor keys, no Esc and no
 * Ctrl, which between them are most of how Claude Code and tmux are driven:
 * arrows move through the input and the permission prompts, Esc interrupts,
 * Shift+Tab cycles the permission mode, Ctrl+C stops a run and Ctrl+B is the
 * tmux prefix. Without them the terminal is readable from a phone but not
 * usable from one.
 *
 * This is appended to ttyd's own index.html at image build time (see
 * build-index.py) rather than shipped as a replacement client: ttyd inlines its
 * entire front end into that one file, so anything we author ourselves would be
 * a fork of it that silently rots at the next ttyd release. Appending keeps
 * ttyd's client authoritative -- we only add a bar and drive the terminal that
 * is already there.
 *
 * How the keys reach the shell: a synthetic KeyboardEvent is dispatched at
 * xterm.js's hidden helper textarea, which is where xterm.js binds its own
 * keydown handler. That is deliberately the same path a physical key takes, so
 * xterm.js -- not this file -- decides the bytes. It matters most for the
 * cursor keys: an application in DECCKM (application cursor keys) mode, which
 * both tmux and Claude Code's Ink UI turn on, expects ESC O A where a plain
 * shell expects ESC [ A. Writing the bytes ourselves would mean tracking that
 * mode; going through the keyboard path means xterm.js already has.
 */
(function () {
    'use strict';

    /* Touch only. A desktop already has these keys, and matchMedia's coarse
     * pointer is the primary pointing device -- a laptop with a touchscreen
     * still reports fine, so it keeps the desktop terminal untouched. */
    if (!window.matchMedia || !window.matchMedia('(pointer: coarse)').matches) {
        return;
    }

    var STORE_KEY = 'claude-terminal.mobile-keys.collapsed';
    var REPEAT_DELAY = 400;
    var REPEAT_INTERVAL = 60;

    /* keyCode, not key, is what xterm.js switches on when it evaluates a
     * keyboard event, so it is the field that must be right. `key`/`code` are
     * set to match anyway: they are what any other listener would read. */
    var KEYS = [
        { id: 'esc', label: 'esc', key: 'Escape', code: 'Escape', keyCode: 27, seq: '\x1b' },
        { id: 'tab', label: 'tab', key: 'Tab', code: 'Tab', keyCode: 9, seq: '\t' },
        { id: 'shifttab', label: '⇧tab', key: 'Tab', code: 'Tab', keyCode: 9, shiftKey: true, seq: '\x1b[Z' },
        { id: 'ctrl', label: 'ctrl', sticky: true },
        { id: 'left', label: '←', key: 'ArrowLeft', code: 'ArrowLeft', keyCode: 37, repeat: true, seq: '\x1b[D', appSeq: '\x1bOD' },
        { id: 'down', label: '↓', key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, repeat: true, seq: '\x1b[B', appSeq: '\x1bOB' },
        { id: 'up', label: '↑', key: 'ArrowUp', code: 'ArrowUp', keyCode: 38, repeat: true, seq: '\x1b[A', appSeq: '\x1bOA' },
        { id: 'right', label: '→', key: 'ArrowRight', code: 'ArrowRight', keyCode: 39, repeat: true, seq: '\x1b[C', appSeq: '\x1bOC' }
    ];

    var SYNTHETIC = '__claudeTerminalMobileKey';
    var ctrlArmed = false;
    var collapsed = false;
    var bar, keyRow, toggleButton, ctrlButton;

    function helperTextarea() {
        /* Queried per press, never cached: ttyd rebuilds the terminal (and this
         * element with it) whenever the WebSocket reconnects, which on a phone
         * happens every time the browser backgrounds the tab. */
        return document.querySelector('.xterm-helper-textarea');
    }

    function stamp(event) {
        try {
            Object.defineProperty(event, SYNTHETIC, { value: true });
        } catch (e) {
            /* non-fatal: only the Ctrl interceptor reads it */
        }
        return event;
    }

    function makeKeyEvent(type, init) {
        var event = new KeyboardEvent(type, init);
        /* keyCode and which are legacy fields. Browsers do honour them in the
         * constructor's init dictionary, but they are not in the modern spec,
         * so pin them afterwards rather than trust that. */
        ['keyCode', 'which'].forEach(function (name) {
            if (event[name] !== init.keyCode) {
                try {
                    Object.defineProperty(event, name, { get: function () { return init.keyCode; } });
                } catch (e) {
                    /* if this fails the constructor value stands */
                }
            }
        });
        return stamp(event);
    }

    /* Dispatch a key at xterm.js and report whether it took it.
     *
     * xterm.js calls preventDefault() on any event it turns into terminal
     * input, so defaultPrevented is a genuine answer to "did that work?" rather
     * than a guess -- which is what makes the byte-level fallback below safe to
     * attempt instead of a blind double-send. */
    function dispatchKey(init) {
        var target = helperTextarea();
        if (!target) {
            return false;
        }
        var down = makeKeyEvent('keydown', init);
        target.dispatchEvent(down);
        target.dispatchEvent(makeKeyEvent('keyup', init));
        return down.defaultPrevented;
    }

    function applicationCursorKeys() {
        try {
            return !!(window.term && window.term.modes && window.term.modes.applicationCursorKeysMode);
        } catch (e) {
            return false;
        }
    }

    /* Last resort for a future xterm.js that stops honouring synthetic events:
     * write the bytes through the terminal's own input API, which is the same
     * entry point its keyboard handler ends at. */
    function writeBytes(data) {
        if (!data) {
            return;
        }
        try {
            if (window.term && typeof window.term.input === 'function') {
                window.term.input(data, true);
            }
        } catch (e) {
            /* nothing further to try */
        }
    }

    function pressKey(spec) {
        var withCtrl = ctrlArmed;
        var handled = dispatchKey({
            key: spec.key,
            code: spec.code,
            keyCode: spec.keyCode,
            ctrlKey: withCtrl,
            shiftKey: !!spec.shiftKey,
            altKey: false,
            metaKey: false,
            bubbles: true,
            cancelable: true,
            composed: true
        });

        if (!handled) {
            writeBytes(spec.appSeq && applicationCursorKeys() ? spec.appSeq : spec.seq);
        }
        if (withCtrl) {
            setCtrl(false);
        }
    }

    /* Ctrl is sticky: tap it, then the next key -- from this bar or from the
     * software keyboard -- arrives with Ctrl held. Intercepting the software
     * keyboard is the awkward half, because a real event's ctrlKey is read-only
     * and iOS reports on-screen typing inconsistently: some keystrokes arrive
     * as a keydown carrying the character, others only as an input event with a
     * keydown of keyCode 229. Both are covered, and both cancel the original so
     * the plain character cannot also land. */
    function sendCtrlChar(character) {
        var upper = character.toUpperCase();
        var handled = dispatchKey({
            key: character,
            code: 'Key' + upper,
            keyCode: upper.charCodeAt(0),
            ctrlKey: true,
            shiftKey: false,
            altKey: false,
            metaKey: false,
            bubbles: true,
            cancelable: true,
            composed: true
        });
        if (!handled) {
            var ordinal = upper.charCodeAt(0);
            if (ordinal >= 64 && ordinal <= 95) {
                writeBytes(String.fromCharCode(ordinal & 31));
            }
        }
    }

    function interceptKeydown(event) {
        if (event[SYNTHETIC]) {
            return;
        }
        var character = event.key;
        if (!character || character.length !== 1) {
            return; /* 229/Unidentified: the input listener below takes it */
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        setCtrl(false);
        sendCtrlChar(character);
    }

    function interceptBeforeInput(event) {
        var data = event.data;
        if (!data || data.length !== 1) {
            return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        setCtrl(false);
        sendCtrlChar(data);
    }

    function setCtrl(armed) {
        if (armed === ctrlArmed) {
            return;
        }
        ctrlArmed = armed;
        var method = armed ? 'addEventListener' : 'removeEventListener';
        window[method]('keydown', interceptKeydown, true);
        window[method]('beforeinput', interceptBeforeInput, true);
        if (ctrlButton) {
            ctrlButton.classList.toggle('mkb-armed', armed);
            ctrlButton.setAttribute('aria-pressed', armed ? 'true' : 'false');
        }
    }

    function makeButton(label, ariaLabel, className) {
        var button = document.createElement('button');
        button.type = 'button';
        button.className = 'mkb-key' + (className ? ' ' + className : '');
        button.textContent = label;
        button.setAttribute('aria-label', ariaLabel);
        /* The whole point of preventDefault here: a tap must not move focus off
         * the terminal's textarea, because on iOS that dismisses the software
         * keyboard -- so every press would cost a re-tap to get it back. */
        button.addEventListener('pointerdown', function (event) { event.preventDefault(); });
        button.addEventListener('mousedown', function (event) { event.preventDefault(); });
        button.addEventListener('touchstart', function (event) { event.preventDefault(); }, { passive: false });
        return button;
    }

    function bindPress(button, action, repeats) {
        var timer = null;
        var interval = null;

        function stop() {
            if (timer) { clearTimeout(timer); timer = null; }
            if (interval) { clearInterval(interval); interval = null; }
        }

        function start(event) {
            /* Acting on press rather than click: click is what iOS synthesises
             * ~300ms later, and a cursor key that lags a third of a second
             * feels broken. */
            event.preventDefault();
            action();
            if (!repeats) {
                return;
            }
            stop();
            timer = setTimeout(function () {
                interval = setInterval(action, REPEAT_INTERVAL);
            }, REPEAT_DELAY);
        }

        if (window.PointerEvent) {
            button.addEventListener('pointerdown', start);
            ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (name) {
                button.addEventListener(name, stop);
            });
        } else {
            button.addEventListener('touchstart', start, { passive: false });
            ['touchend', 'touchcancel'].forEach(function (name) {
                button.addEventListener(name, stop);
            });
        }
        window.addEventListener('blur', stop);
    }

    function refit() {
        /* ttyd exposes the fit addon as term.fit(); without it the pty keeps
         * the old row count and Claude Code redraws over the bar. */
        window.requestAnimationFrame(function () {
            try {
                if (window.term && typeof window.term.fit === 'function') {
                    window.term.fit();
                }
            } catch (e) {
                /* a wrong row count is survivable; an exception here is not */
            }
        });
    }

    function applyCollapsed() {
        bar.classList.toggle('mkb-collapsed', collapsed);
        keyRow.hidden = collapsed;
        toggleButton.textContent = collapsed ? '⌨' : '▾';
        toggleButton.setAttribute('aria-label', collapsed ? 'Show key bar' : 'Hide key bar');
        toggleButton.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
        document.documentElement.style.setProperty('--mkb-height', (collapsed ? 28 : 44) + 'px');
        if (collapsed) {
            setCtrl(false);
        }
        refit();
    }

    function toggleCollapsed() {
        collapsed = !collapsed;
        try {
            window.localStorage.setItem(STORE_KEY, collapsed ? '1' : '0');
        } catch (e) {
            /* private browsing: the choice just does not persist */
        }
        applyCollapsed();
    }

    /* Keep the bar above the software keyboard.
     *
     * position:fixed anchors to the LAYOUT viewport, which iOS does not shrink
     * when the keyboard opens -- so a plain bottom:0 bar sits behind the
     * keyboard, exactly where it is needed and cannot be seen. visualViewport
     * is what reports the actually-visible region. */
    function trackViewport() {
        var viewport = window.visualViewport;
        if (!viewport) {
            return;
        }
        var reposition = function () {
            var hidden = window.innerHeight - (viewport.height + viewport.offsetTop);
            bar.style.transform = 'translateY(-' + Math.max(0, Math.round(hidden)) + 'px)';
        };
        viewport.addEventListener('resize', reposition);
        viewport.addEventListener('scroll', reposition);
        reposition();
    }

    function styles() {
        return [
            ':root { --mkb-height: 44px; }',
            /* ttyd sizes its container to the full page; take the bar's height
               out of it so the terminal is never drawn underneath. */
            '#terminal-container { height: calc(100% - var(--mkb-height) - env(safe-area-inset-bottom, 0px)) !important; }',
            '#mkb-bar { position: fixed; left: 0; right: 0; bottom: 0; z-index: 2147483000;',
            '  display: flex; align-items: center; gap: 4px; box-sizing: border-box;',
            '  padding: 4px 6px calc(4px + env(safe-area-inset-bottom, 0px)) 6px;',
            '  background: #15161e; border-top: 1px solid #414868;',
            '  font: 500 15px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;',
            '  touch-action: none; -webkit-user-select: none; user-select: none; }',
            '#mkb-keys { display: flex; align-items: center; gap: 4px; flex: 1 1 auto; }',
            '.mkb-key { flex: 1 1 auto; min-width: 0; height: 36px; padding: 0 2px;',
            '  display: flex; align-items: center; justify-content: center;',
            '  color: #c0caf5; background: #1f2335; border: 1px solid #414868; border-radius: 6px;',
            '  font: inherit; -webkit-appearance: none; appearance: none; cursor: pointer; }',
            '.mkb-key:active { background: #33467c; }',
            '.mkb-key.mkb-armed { background: #d97757; border-color: #d97757; color: #15161e; }',
            '.mkb-toggle { flex: 0 0 auto; width: 36px; }',
            '#mkb-bar.mkb-collapsed { padding-top: 2px; }',
            '#mkb-bar.mkb-collapsed .mkb-toggle { height: 24px; }'
        ].join('\n');
    }

    function build() {
        var style = document.createElement('style');
        style.textContent = styles();
        document.head.appendChild(style);

        bar = document.createElement('div');
        bar.id = 'mkb-bar';

        keyRow = document.createElement('div');
        keyRow.id = 'mkb-keys';

        KEYS.forEach(function (spec) {
            var button = makeButton(spec.label, spec.id === 'ctrl' ? 'Control (sticky)' : spec.label);
            if (spec.sticky) {
                ctrlButton = button;
                button.setAttribute('aria-pressed', 'false');
                bindPress(button, function () { setCtrl(!ctrlArmed); }, false);
            } else {
                bindPress(button, function () { pressKey(spec); }, !!spec.repeat);
            }
            keyRow.appendChild(button);
        });

        toggleButton = makeButton('▾', 'Hide key bar', 'mkb-toggle');
        bindPress(toggleButton, toggleCollapsed, false);

        bar.appendChild(keyRow);
        bar.appendChild(toggleButton);
        document.body.appendChild(bar);

        try {
            collapsed = window.localStorage.getItem(STORE_KEY) === '1';
        } catch (e) {
            collapsed = false;
        }
        applyCollapsed();
        trackViewport();
        window.addEventListener('orientationchange', refit);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', build);
    } else {
        build();
    }
}());
