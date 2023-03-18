import Foundation
import SwiftIndexStore
import Shared

struct SwiftFileIndexingState {
    let file: SourceFile
    let declarations: [Declaration]
    let childDeclsByParentUsr: [String: Set<Declaration>]
    let referencesByUsr: [String: Set<Reference>]
    let danglingReferences: [Reference]
    let varParameterUsrs: Set<String>
}
