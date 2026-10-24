import AppKit

enum Dialogs {
    /// Asks for the partially downloaded file to watch.
    static func askDownloadFile() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a Download"
        panel.message = "Choose the file that is being downloaded (e.g. .crdownload, .part or .download)."
        panel.prompt = "Watch"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Explains the one-time closed-display setup before the admin password prompt appears.
    static func confirmHelperInstall() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set Up Closed-Display Mode?"
        alert.informativeText = """
            Keeping your Mac awake with the lid closed requires changing a system power setting. \
            Wakeful will ask for your password once to allow this, and never again.

            Only the commands “pmset -a disablesleep 0” and “pmset -a disablesleep 1” are allowed. \
            Your password is not stored. You can remove this later in Settings.
            """
        alert.addButton(withTitle: "Set Up")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
