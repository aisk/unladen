// Builds the control panel's page into the server: Panel/panel.html and
// Panel/panel.js become `AdminPage.html`, a string compiled into the
// binary, so the server reads no file at run time (and needs no Bundle,
// which would bring in the whole of Foundation on Linux).

import Foundation
import PackagePlugin

@main
struct EmbedPanel: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let panel = target.directoryURL.appending(path: "Panel")
        let html = panel.appending(path: "panel.html")
        let script = panel.appending(path: "panel.js")
        let output = context.pluginWorkDirectoryURL.appending(path: "PanelPage.swift")
        return [
            .buildCommand(
                displayName: "Embedding the control panel",
                executable: try context.tool(named: "EmbedPanelTool").url,
                arguments: [html.path(), script.path(), output.path()],
                inputFiles: [html, script],
                outputFiles: [output],
            ),
        ]
    }
}
