import Foundation

final class RooCodeScanner: ClineScanner {
    override var category: ConversationCategory { .rooCode }

    override var envVarName: String { "ROO_CODE_HOME" }

    override var defaultStorageRelativePath: String {
        "Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline"
    }

    override init(storageURL: URL? = nil) {
        super.init(storageURL: storageURL)
    }
}
