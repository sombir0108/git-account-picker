#!/usr/bin/env python3
"""Native Linux account picker window (GTK 4 + libadwaita), matching the
Windows popup and the macOS window.

Needs Python 3 with PyGObject and the GTK 4 / libadwaita introspection data
(preinstalled on recent GNOME desktops). Exits with status 3 when they are
missing, so lib/picker-common.sh falls back to its zenity/kdialog dialogs.

Modes (--mode):
  manage  (default; the desktop launcher): switches, adds and removes
          accounts itself and stays open until closed.
  choose  (git / IDE prompts): adding and removing happen in place; Switch
          prints the chosen account and exits, Cancel prints nothing.
  login   (sign-in only): runs the browser sign-in, shows the one-time code
          and exits when it's done.
Other options: --host, --accounts a,b,c, --active NAME, --subtitle TEXT,
  --icon PATH, --render PATH [--theme light|dark] (writes a PNG of the
  window instead of showing it; used by the automatic checks).
"""
import argparse
import os
import re
import subprocess
import sys
import threading

try:
    import gi

    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gdk, Gio, GLib, Gtk
except (ImportError, ValueError):
    sys.exit(3)

DEVICE_PAGE = "https://github.com/login/device"
APP_ID = "io.github.sombirverma.GitAccountPicker"

CSS = """
.switch-button { background: #2da44e; color: white; }
.switch-button:hover { background: #2c974b; }
.switch-button:disabled { background: alpha(#2da44e, 0.45); }
.remove-button { color: @error_color; }
.active-label { color: @success_color; }
.banner { border-radius: 8px; padding: 10px; }
.banner.info { background: alpha(@accent_bg_color, 0.15); }
.banner.success { background: alpha(@success_color, 0.17); }
.banner.warning { background: alpha(@warning_color, 0.20); }
.code { font-family: monospace; font-size: 28px; font-weight: bold; }
"""


# --- GitHub CLI -----------------------------------------------------------------

def gh(*args):
    """Runs gh with its input not on a terminal, so it never asks questions
    (its "Authenticate Git with your GitHub credentials?" would replace this
    tool's credential helper). Returns (status, output)."""
    try:
        p = subprocess.run(["gh", *args], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except OSError as e:
        return 127, str(e)
    return p.returncode, p.stdout


def gh_installed():
    return gh("--version")[0] == 0


def gh_accounts(host):
    return re.findall(r"Logged in to \S+ account (\S+)", gh("auth", "status", "--hostname", host)[1])


def gh_active(host):
    return gh("config", "get", "-h", host, "user")[1].strip()


def login_code(text):
    """Newer gh: "One-time code (ABCD-1234) copied"; older: "one-time code: ABCD-1234"."""
    m = re.search(r"code[^A-Z0-9]*([A-Z0-9]{4}-[A-Z0-9]{4})", text)
    return m.group(1) if m else None


# --- Settings (shared with the Windows and macOS windows) --------------------------

def config_dir():
    if os.environ.get("GIT_ACCOUNT_PICKER_CONFIG_DIR"):
        return os.environ["GIT_ACCOUNT_PICKER_CONFIG_DIR"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "git-account-picker")


def forget_owners(account):
    """Forgets repo owners remembered for an account that was removed."""
    path = os.path.join(config_dir(), "owners")
    try:
        with open(path) as f:
            lines = f.read().splitlines()
        kept = [l for l in lines if len(l.split()) < 2 or l.split()[1] != account]
        with open(path, "w") as f:
            f.write("".join(l + "\n" for l in kept))
    except OSError:
        pass


class Settings:
    def __init__(self):
        self.top_most = True
        self.opacity = 100
        self.theme = "auto"
        self.persist = True
        self.path = os.path.join(config_dir(), "ui-settings")
        try:
            with open(self.path) as f:
                for line in f.read().splitlines():
                    key, _, value = line.partition("=")
                    if key == "topmost":
                        self.top_most = value == "true"
                    elif key == "opacity" and value.isdigit():
                        self.opacity = min(100, max(40, int(value)))
                    elif key == "theme" and value in ("auto", "light", "dark"):
                        self.theme = value
        except OSError:
            pass

    def save(self):
        if not self.persist:
            return
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "w") as f:
                f.write("topmost=%s\nopacity=%d\ntheme=%s\n"
                        % (str(self.top_most).lower(), self.opacity, self.theme))
        except OSError:
            pass


# --- Small widget helpers ----------------------------------------------------------

def label(text, *classes, wrap=False, xalign=0.0):
    w = Gtk.Label(label=text, xalign=xalign)
    for c in classes:
        w.add_css_class(c)
    if wrap:
        w.set_wrap(True)
        w.set_max_width_chars(48)
        if xalign == 0.5:
            w.set_justify(Gtk.Justification.CENTER)
    return w


def hbox(spacing=8):
    return Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)


def vbox(spacing=8):
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)


def spacer():
    w = Gtk.Box()
    w.set_hexpand(True)
    return w


def margins(widget, size):
    widget.set_margin_top(size)
    widget.set_margin_bottom(size)
    widget.set_margin_start(size)
    widget.set_margin_end(size)
    return widget


def save_png(widget, path):
    """Writes what a realized window currently shows to a PNG."""
    w, h = widget.get_width(), widget.get_height()
    snapshot = Gtk.Snapshot()
    Gtk.WidgetPaintable.new(widget).snapshot(snapshot, w, h)
    node = snapshot.to_node()
    texture = widget.get_native().get_renderer().render_texture(node, None)
    texture.save_to_png(path)


# --- The app -----------------------------------------------------------------------

class PickerApp(Adw.Application):
    def __init__(self, opts):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.opts = opts
        self.settings = Settings()
        if opts.render:
            self.settings.persist = False
            if opts.theme:
                self.settings.theme = opts.theme
        self.accounts = opts.accounts or []
        self.active = opts.active or ""
        self.busy = False
        self.login_proc = None
        self.login_output = ""
        self.login_cancelled = False
        self.code_window = None
        self.code_label = None
        self.window = None

    # Running things in the background, updating the window afterwards.
    def later(self, work, done):
        def run():
            result = work()
            GLib.idle_add(lambda: done(result) or False)
        threading.Thread(target=run, daemon=True).start()

    @property
    def manage(self):
        return self.opts.mode == "manage"

    # --- startup --------------------------------------------------------------

    def do_activate(self):
        provider = Gtk.CssProvider()
        if hasattr(provider, "load_from_string"):
            provider.load_from_string(CSS)
        else:
            try:
                provider.load_from_data(CSS.encode())
            except TypeError:
                provider.load_from_data(CSS, -1)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.apply_theme()

        if self.opts.mode == "login":
            self.show_code_window(None, standalone=True)
            if self.opts.render:
                self.set_code("ABCD-1234")
                self.render_soon(self.code_window)
            else:
                self.start_login()
            return

        self.build_window()
        if self.opts.render:
            self.welcome()
            self.render_soon(self.window)
            return
        if self.opts.mode == "choose" and self.opts.accounts is not None:
            self.welcome()
        else:
            self.load()

    def render_soon(self, window):
        window.present()

        def shot():
            save_png(window, self.opts.render)
            self.quit()
            return False
        GLib.timeout_add(1200, shot)

    def apply_theme(self):
        theme = self.settings.theme
        if theme == "auto":
            theme = os.environ.get("GIT_ACCOUNT_PICKER_THEME", "auto")
        scheme = {"light": Adw.ColorScheme.FORCE_LIGHT, "dark": Adw.ColorScheme.FORCE_DARK}
        Adw.StyleManager.get_default().set_color_scheme(scheme.get(theme, Adw.ColorScheme.DEFAULT))

    # --- main window ------------------------------------------------------------

    def build_window(self):
        win = Adw.ApplicationWindow(application=self)
        win.set_title("GitHub Account Picker")
        win.set_default_size(460, -1)
        win.set_resizable(False)
        win.set_opacity(self.settings.opacity / 100)
        self.window = win

        page = vbox(0)
        header = Adw.HeaderBar()
        header.set_title_widget(Adw.WindowTitle(title="GitHub Account Picker", subtitle=""))
        self.theme_button = Gtk.Button()
        self.theme_button.set_tooltip_text("Theme: Auto follows your desktop. Click to switch between Auto, Light and Dark.")
        self.theme_button.connect("clicked", self.on_theme)
        self.update_theme_button()
        header.pack_end(self.theme_button)
        page.append(header)

        body = margins(vbox(14), 18)
        page.append(body)

        top = hbox(12)
        if self.opts.icon and os.path.exists(self.opts.icon):
            icon = Gtk.Image.new_from_file(self.opts.icon)
            icon.set_pixel_size(44)
            top.append(icon)
        titles = vbox(2)
        titles.append(label("GitHub accounts", "title-2"))
        subtitle = self.opts.subtitle or (
            ("Switch" if self.manage else "Choose") + " the account git uses for " + self.opts.host)
        titles.append(label(subtitle, "dim-label"))
        top.append(titles)
        body.append(top)

        self.list = Gtk.ListBox()
        self.list.add_css_class("boxed-list")
        self.list.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self.list.set_activate_on_single_click(False)
        self.list.connect("row-activated", lambda *_: self.on_switch())
        self.list.connect("row-selected", lambda *_: self.update_buttons())
        self.scroller = Gtk.ScrolledWindow()
        self.scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroller.set_child(self.list)
        body.append(self.scroller)

        self.banner = hbox(8)
        self.banner.add_css_class("banner")
        self.banner_icon = Gtk.Image()
        self.banner_text = label("", wrap=True)
        self.banner_text.set_hexpand(True)
        self.banner.append(self.banner_icon)
        self.banner.append(self.banner_text)
        self.banner.set_visible(False)
        body.append(self.banner)

        buttons = hbox(8)
        add = Gtk.Button(child=Adw.ButtonContent(icon_name="list-add-symbolic", label="Add account"))
        add.connect("clicked", lambda *_: self.start_login())
        self.remove_button = Gtk.Button(label="Remove…")
        self.remove_button.add_css_class("remove-button")
        self.remove_button.connect("clicked", lambda *_: self.on_remove())
        close = Gtk.Button(label="Close" if self.manage else "Cancel")
        close.connect("clicked", lambda *_: self.quit())
        self.switch_button = Gtk.Button(label="Switch")
        self.switch_button.add_css_class("switch-button")
        self.switch_button.connect("clicked", lambda *_: self.on_switch())
        for b in (add, self.remove_button, spacer(), close, self.switch_button):
            buttons.append(b)
        body.append(buttons)

        body.append(Gtk.Separator())

        footer = hbox(8)
        top_switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        top_switch.set_active(False)
        # GTK 4 can't keep a window above others (Wayland doesn't allow it).
        top_switch.set_sensitive(False)
        top_label = label("Always on top", "dim-label")
        tip = "Linux desktops don't let apps keep themselves on top, so this is off here."
        top_switch.set_tooltip_text(tip)
        top_label.set_tooltip_text(tip)
        footer.append(top_switch)
        footer.append(top_label)
        footer.append(spacer())
        footer.append(label("Opacity", "dim-label"))
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 40, 100, 1)
        scale.set_draw_value(False)
        scale.set_size_request(120, -1)
        scale.set_value(self.settings.opacity)
        self.opacity_label = label("%d%%" % self.settings.opacity)
        self.opacity_label.set_width_chars(4)
        scale.connect("value-changed", self.on_opacity)
        footer.append(scale)
        footer.append(self.opacity_label)
        body.append(footer)

        win.set_content(page)
        win.connect("close-request", lambda *_: self.quit() or False)
        self.fill()
        win.present()

    def fill(self, select=None):
        while True:
            row = self.list.get_row_at_index(0)
            if row is None:
                break
            self.list.remove(row)
        for name in self.accounts:
            row = Gtk.ListBoxRow()
            box = margins(hbox(12), 8)
            box.set_margin_start(12)
            box.append(Adw.Avatar.new(36, name, True))
            text = vbox(2)
            text.set_valign(Gtk.Align.CENTER)
            text.append(label(name, "heading"))
            if name == self.active:
                text.append(label("● Active now", "caption", "active-label"))
            else:
                text.append(label("Signed in", "caption", "dim-label"))
            box.append(text)
            row.set_child(box)
            self.list.append(row)
        rows = min(5, max(1, len(self.accounts)))
        self.scroller.set_max_content_height(-1)
        self.scroller.set_min_content_height(rows * 58)
        self.scroller.set_max_content_height(rows * 58)
        want = select or self.active
        index = self.accounts.index(want) if want in self.accounts else 0
        if self.accounts:
            self.list.select_row(self.list.get_row_at_index(index))
        self.update_buttons()

    def selected(self):
        row = self.list.get_selected_row()
        return self.accounts[row.get_index()] if row is not None else None

    def update_buttons(self):
        has = self.selected() is not None and not self.busy
        self.switch_button.set_sensitive(has)
        self.remove_button.set_sensitive(has)

    def say(self, kind, text):
        if self.window is None:
            return
        for k in ("info", "success", "warning"):
            self.banner.remove_css_class(k)
        self.banner.add_css_class(kind)
        icons = {"success": "emblem-ok-symbolic", "warning": "dialog-warning-symbolic"}
        self.banner_icon.set_from_icon_name(icons.get(kind, "dialog-information-symbolic"))
        self.banner_text.set_label(text)
        self.banner.set_visible(True)

    def welcome(self):
        if not self.accounts:
            self.say("info", "No GitHub account is signed in here yet. Click Add account to sign in.")
        elif self.manage:
            self.say("info", "git is using %s right now. Pick an account and press Switch." % self.active
                     if self.active else "Pick an account and press Switch.")

    # --- settings ---------------------------------------------------------------

    def update_theme_button(self):
        labels = {"auto": "◐  Auto", "light": "☀  Light", "dark": "☾  Dark"}
        self.theme_button.set_label(labels[self.settings.theme])

    def on_theme(self, *_):
        self.settings.theme = {"auto": "light", "light": "dark"}.get(self.settings.theme, "auto")
        self.settings.save()
        self.update_theme_button()
        self.apply_theme()

    def on_opacity(self, scale):
        value = int(round(scale.get_value()))
        self.settings.opacity = value
        self.window.set_opacity(value / 100)
        self.opacity_label.set_label("%d%%" % value)
        self.settings.save()

    # --- actions ----------------------------------------------------------------

    def load(self):
        self.busy = True
        host = self.opts.host

        def work():
            if not gh_installed():
                return None
            return gh_accounts(host), gh_active(host)

        def done(result):
            self.busy = False
            if result is None:
                self.say("warning", "The GitHub CLI (gh) isn't installed. Install it from https://cli.github.com/, then open this again.")
                self.update_buttons()
                return
            self.accounts, self.active = result
            self.fill()
            self.welcome()
        self.later(work, done)

    def on_switch(self):
        target = self.selected()
        if target is None or self.busy:
            return
        if not self.manage:
            # Choose mode: the caller switches; just answer.
            print(target, flush=True)
            self.quit()
            return
        if target == self.active:
            self.say("info", "%s is already the active account." % target)
            return
        self.say("info", "Switching to %s…" % target)
        self.busy = True
        self.update_buttons()
        host = self.opts.host

        def work():
            switched = gh("auth", "switch", "--hostname", host, "--user", target)[0] == 0
            valid = switched and gh("api", "user", "--hostname", host)[0] == 0
            return switched, valid

        def done(result):
            switched, valid = result
            self.busy = False
            if not switched:
                self.say("warning", "Couldn't switch to %s. Try removing it and adding it again." % target)
            else:
                self.active = target
                self.fill(select=target)
                if valid:
                    self.say("success", "Switched. git now uses %s." % target)
                else:
                    self.say("warning", "Switched to %s, but its sign-in has expired. Remove it and add it again to sign in." % target)
            self.update_buttons()
        self.later(work, done)

    def on_remove(self):
        target = self.selected()
        if target is None:
            return
        dialog = Adw.Window(transient_for=self.window, modal=True)
        dialog.set_title("Remove account")
        dialog.set_resizable(False)
        dialog.set_default_size(400, -1)
        content = vbox(0)
        bar = Adw.HeaderBar()
        bar.add_css_class("flat")
        content.append(bar)
        body = margins(vbox(12), 20)
        body.set_margin_top(4)
        body.append(label("Sign out of %s on this computer?" % target, "title-4", wrap=True))
        body.append(label("It is removed from this list and git stops using it. Your GitHub account "
                          "itself is not deleted, and you can add it back with Add account.",
                          "dim-label", wrap=True))
        row = hbox(8)
        row.append(spacer())
        cancel = Gtk.Button(label="Cancel")
        cancel.connect("clicked", lambda *_: dialog.close())
        remove = Gtk.Button(label="Remove")
        remove.add_css_class("destructive-action")

        def confirmed(*_):
            dialog.close()
            self.remove(target)
        remove.connect("clicked", confirmed)
        row.append(cancel)
        row.append(remove)
        body.append(row)
        content.append(body)
        dialog.set_content(content)
        dialog.present()

    def remove(self, target):
        self.busy = True
        self.update_buttons()
        host = self.opts.host

        def work():
            gh("auth", "logout", "--hostname", host, "--user", target)
            forget_owners(target)
            return gh_accounts(host), gh_active(host)

        def done(result):
            self.busy = False
            self.accounts, self.active = result
            self.fill()
            if self.accounts:
                self.say("success", "Signed out of %s on this computer." % target)
            else:
                self.say("warning", "Signed out of %s. No accounts are left; use Add account to sign in." % target)
        self.later(work, done)

    # --- browser sign-in ----------------------------------------------------------

    def start_login(self):
        """gh prints a one-time code and waits; we open the page, copy the code
        and show it until gh finishes."""
        if self.login_proc is not None:
            return
        try:
            proc = subprocess.Popen(
                ["gh", "auth", "login", "--hostname", self.opts.host, "--git-protocol", "https",
                 "--web", "--scopes", "workflow"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        except OSError:
            self.say("warning", "Couldn't start the GitHub sign-in. Is the GitHub CLI (gh) installed?")
            if self.opts.mode == "login":
                self.quit()
            return
        self.login_proc = proc
        self.login_output = ""
        self.login_cancelled = False
        before = list(self.accounts)
        if self.window is not None:
            self.show_code_window(self.window)
        self.say("info", "Starting the GitHub sign-in…")

        def read():
            for line in proc.stdout:
                GLib.idle_add(self.login_line, line)
            proc.wait()
            GLib.idle_add(self.login_finished, before)
        threading.Thread(target=read, daemon=True).start()

    def login_line(self, line):
        self.login_output += line
        code = login_code(self.login_output)
        if code and self.code_label is not None and self.code_label.get_label() != code:
            clipboard = Gdk.Display.get_default().get_clipboard()
            clipboard.set_content(Gdk.ContentProvider.new_for_bytes(
                "text/plain;charset=utf-8", GLib.Bytes.new(code.encode())))
            self.open_device_page()
            self.set_code(code)
        return False

    def open_device_page(self, *_):
        try:
            Gio.AppInfo.launch_default_for_uri(DEVICE_PAGE, None)
        except GLib.Error:
            pass

    def cancel_login(self, *_):
        self.login_cancelled = True
        if self.login_proc is not None:
            self.login_proc.terminate()

    def login_finished(self, before):
        had_code = self.code_label is not None and self.code_label.get_label() not in ("", "…")
        self.login_proc = None
        if self.code_window is not None:
            self.code_window.close()
            self.code_window = None
            self.code_label = None
        if self.opts.mode == "login":
            self.quit()
            return False
        host = self.opts.host

        def done(result):
            self.accounts, self.active = result
            added = [a for a in self.accounts if a not in before]
            self.fill(select=added[0] if added else None)
            if added:
                self.say("success", "Added %s. Press Switch to start using it." % added[0])
            elif self.login_cancelled:
                self.say("info", "Sign-in cancelled.")
            elif not had_code:
                last = (self.login_output.strip().splitlines() or [""])[-1]
                self.say("warning", "Couldn't start the GitHub sign-in. " + last)
            else:
                self.say("warning", "No new account was added. If the browser used an account that's already "
                                    "here, sign out of GitHub there or use a private window, then try again.")
        self.later(lambda: (gh_accounts(host), gh_active(host)), done)
        return False

    def show_code_window(self, parent, standalone=False):
        win = Adw.ApplicationWindow(application=self) if standalone else Adw.Window(transient_for=parent, modal=True)
        win.set_title("Add GitHub account")
        win.set_resizable(False)
        win.set_default_size(400, -1)
        content = vbox(0)
        bar = Adw.HeaderBar()
        bar.add_css_class("flat")
        content.append(bar)
        body = margins(vbox(12), 22)
        body.set_margin_top(0)
        key = Gtk.Image.new_from_icon_name("dialog-password-symbolic")
        key.set_pixel_size(32)
        body.append(key)
        body.append(label("Enter this code on GitHub", "title-4", xalign=0.5))
        self.code_label = label("…", "code", xalign=0.5)

        body.append(self.code_label)
        body.append(label("It's copied to your clipboard, and your browser opened github.com/login/device. "
                          "Paste the code there, sign in as the account you want to add, and approve. "
                          "This closes by itself when you're done.", "dim-label", wrap=True, xalign=0.5))
        row = hbox(8)
        row.set_halign(Gtk.Align.CENTER)
        cancel = Gtk.Button(label="Cancel sign-in")
        cancel.connect("clicked", self.cancel_login)
        again = Gtk.Button(label="Open GitHub again")
        again.add_css_class("suggested-action")
        again.connect("clicked", self.open_device_page)
        row.append(cancel)
        row.append(again)
        body.append(row)
        content.append(body)
        win.set_content(content)
        # Closing it (not gh finishing) cancels the sign-in.
        win.connect("close-request", lambda *_: (self.cancel_login() if self.login_proc is not None else None) or False)
        self.code_window = win
        win.present()

    def set_code(self, code):
        if self.code_label is not None:
            self.code_label.set_label(code)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", default="manage", choices=["manage", "choose", "login"])
    p.add_argument("--host", default="github.com")
    p.add_argument("--accounts")
    p.add_argument("--active")
    p.add_argument("--subtitle")
    p.add_argument("--icon")
    p.add_argument("--render")
    p.add_argument("--theme", choices=["light", "dark"])
    opts = p.parse_args()
    opts.accounts = [a for a in opts.accounts.split(",") if a] if opts.accounts is not None else None
    return PickerApp(opts).run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
