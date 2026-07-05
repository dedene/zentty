import Foundation

struct CleanCopyOptions: Equatable, Sendable {
    var flattenMultiLineCommands: Bool
    var commandFlattenAggressiveness: CommandFlattenAggressiveness
    var preserveBlankLinesWhenFlattening: Bool
    var removeBoxDrawing: Bool
    var flattenSlashCommandSelections: Bool
    var stripURLTrackingParameters: Bool
    var quotePathsWithSpaces: Bool

    static let `default` = CleanCopyOptions(
        flattenMultiLineCommands: true,
        commandFlattenAggressiveness: .normal,
        preserveBlankLinesWhenFlattening: false,
        removeBoxDrawing: true,
        flattenSlashCommandSelections: true,
        stripURLTrackingParameters: true,
        quotePathsWithSpaces: true
    )

    static func from(_ clipboard: AppConfig.Clipboard) -> CleanCopyOptions {
        CleanCopyOptions(
            flattenMultiLineCommands: clipboard.flattenMultiLineCommands,
            commandFlattenAggressiveness: clipboard.commandFlattenAggressiveness,
            preserveBlankLinesWhenFlattening: clipboard.preserveBlankLinesWhenFlattening,
            removeBoxDrawing: clipboard.removeBoxDrawing,
            flattenSlashCommandSelections: clipboard.flattenSlashCommandSelections,
            stripURLTrackingParameters: clipboard.stripURLTrackingParameters,
            quotePathsWithSpaces: clipboard.quotePathsWithSpaces
        )
    }
}