import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// @Persistable macro implementation
///
/// Generates Persistable protocol conformance with metadata methods.
///
/// **Supports all layers**:
/// - RecordLayer (RDB): Use #PrimaryKey for relational model
/// - DocumentLayer (DocumentDB): No #PrimaryKey, auto-generates ObjectID
/// - GraphLayer (GraphDB): Define nodes with relationships
///
/// **Generated code includes**:
/// - static var persistableType: String
/// - static var allFields: [String]
/// - static var indexDescriptors: [IndexDescriptor]
/// - static var primaryKeyFields: [String] (if #PrimaryKey exists)
/// - static func fieldNumber(for fieldName: String) -> Int?
/// - static func enumMetadata(for fieldName: String) -> EnumMetadata?
///
/// **Note**: primaryKeyFields is only generated if #PrimaryKey is declared.
/// The Persistable protocol itself does not require primaryKeyFields (layer-independent).
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     #PrimaryKey<User>([\.userID])
///     #Index<User>([\.email], type: ScalarIndexKind(), unique: true)
///
///     var userID: Int64
///     var email: String
///     var name: String
/// }
/// ```
public struct PersistableMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Extract struct name
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("@Persistable can only be applied to structs")
                )
            ])
        }

        let typeName = structDecl.name.text

        // Extract all stored properties (fields)
        var allFields: [String] = []
        var fieldNumbers: [(name: String, number: Int)] = []
        var fieldNumber = 1

        for member in structDecl.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
               varDecl.bindingSpecifier.text == "var" {
                for binding in varDecl.bindings {
                    if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                        let fieldName = pattern.identifier.text
                        allFields.append(fieldName)
                        fieldNumbers.append((name: fieldName, number: fieldNumber))
                        fieldNumber += 1
                    }
                }
            }
        }

        // Extract #PrimaryKey macro calls
        var primaryKeyFields: [String] = []
        for member in structDecl.memberBlock.members {
            if let macroDecl = member.decl.as(MacroExpansionDeclSyntax.self),
               macroDecl.macroName.text == "PrimaryKey" {
                // Extract KeyPaths from arguments
                if let firstArg = macroDecl.arguments.first,
                   let arrayExpr = firstArg.expression.as(ArrayExprSyntax.self) {
                    for element in arrayExpr.elements {
                        if let keyPathExpr = element.expression.as(KeyPathExprSyntax.self),
                           let component = keyPathExpr.components.first,
                           let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                            primaryKeyFields.append(property.declName.baseName.text)
                        }
                    }
                }
            }
        }

        // Extract #Index macro calls and generate IndexDescriptors
        var indexDescriptors: [String] = []

        for member in structDecl.memberBlock.members {
            if let macroDecl = member.decl.as(MacroExpansionDeclSyntax.self),
               macroDecl.macroName.text == "Index" {

                // Extract KeyPaths (first argument)
                var keyPaths: [String] = []
                var indexKindExpr: String?
                var isUnique = false
                var indexName: String?

                for arg in macroDecl.arguments {
                    // First argument: KeyPaths array
                    if arg.label == nil {
                        if let arrayExpr = arg.expression.as(ArrayExprSyntax.self) {
                            for element in arrayExpr.elements {
                                if let keyPathExpr = element.expression.as(KeyPathExprSyntax.self),
                                   let component = keyPathExpr.components.first,
                                   let property = component.component.as(KeyPathPropertyComponentSyntax.self) {
                                    keyPaths.append(property.declName.baseName.text)
                                }
                            }
                        }
                    }
                    // "type:" argument
                    else if let label = arg.label, label.text == "type" {
                        indexKindExpr = arg.expression.description.trimmingCharacters(in: .whitespaces)
                    }
                    // "unique:" argument
                    else if let label = arg.label, label.text == "unique" {
                        if let boolExpr = arg.expression.as(BooleanLiteralExprSyntax.self) {
                            isUnique = boolExpr.literal.text == "true"
                        }
                    }
                    // "name:" argument
                    else if let label = arg.label, label.text == "name" {
                        if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                           let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                            indexName = segment.content.text
                        }
                    }
                }

                guard !keyPaths.isEmpty else { continue }

                // Generate index name if not provided
                let finalIndexName = indexName ?? "\(typeName)_\(keyPaths.joined(separator: "_"))"

                // Generate IndexDescriptor initialization
                let keyPathsArray = "[\(keyPaths.map { "\"\($0)\"" }.joined(separator: ", "))]"
                let kindInit = indexKindExpr ?? "ScalarIndexKind()"
                let optionsInit = isUnique ? ".init(unique: true)" : ".init()"

                let descriptorInit = """
                    IndexDescriptor(
                        name: "\(finalIndexName)",
                        keyPaths: \(keyPathsArray),
                        kind: \(kindInit),
                        commonOptions: \(optionsInit)
                    )
                """

                indexDescriptors.append(descriptorInit)
            }
        }

        // Generate persistableType property
        let persistableTypeDecl: DeclSyntax = """
            public static var persistableType: String { "\(raw: typeName)" }
            """

        // Generate primaryKeyFields property (only if #PrimaryKey exists)
        // Note: This is generated as a member (not an extension) for compatibility
        // with the macro system, but Persistable protocol itself does not require it.
        var decls: [DeclSyntax] = [persistableTypeDecl]

        if !primaryKeyFields.isEmpty {
            let primaryKeyFieldsArray = "[\(primaryKeyFields.map { "\"\($0)\"" }.joined(separator: ", "))]"
            let primaryKeyFieldsDecl: DeclSyntax = """
                public static var primaryKeyFields: [String] { \(raw: primaryKeyFieldsArray) }
                """
            decls.append(primaryKeyFieldsDecl)
        }

        // Generate allFields property
        let allFieldsArray = "[\(allFields.map { "\"\($0)\"" }.joined(separator: ", "))]"
        let allFieldsDecl: DeclSyntax = """
            public static var allFields: [String] { \(raw: allFieldsArray) }
            """
        decls.append(allFieldsDecl)

        // Generate indexDescriptors property
        let indexDescriptorsArray = indexDescriptors.isEmpty
            ? "[]"
            : "[\n            \(indexDescriptors.joined(separator: ",\n            "))\n        ]"
        let indexDescriptorsDecl: DeclSyntax = """
            public static var indexDescriptors: [IndexDescriptor] { \(raw: indexDescriptorsArray) }
            """
        decls.append(indexDescriptorsDecl)

        // Generate fieldNumber method
        var fieldNumberCases: [String] = []
        for (name, number) in fieldNumbers {
            fieldNumberCases.append("case \"\(name)\": return \(number)")
        }
        let fieldNumberBody = fieldNumberCases.isEmpty
            ? "return nil"
            : """
            switch fieldName {
                    \(fieldNumberCases.joined(separator: "\n        "))
                    default: return nil
                }
            """
        let fieldNumberDecl: DeclSyntax = """
            public static func fieldNumber(for fieldName: String) -> Int? {
                \(raw: fieldNumberBody)
            }
            """
        decls.append(fieldNumberDecl)

        // Generate enumMetadata method (default implementation: returns nil)
        let enumMetadataDecl: DeclSyntax = """
            public static func enumMetadata(for fieldName: String) -> EnumMetadata? {
                return nil
            }
            """
        decls.append(enumMetadataDecl)

        return decls
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Generate conformance extension (Persistable, Codable, Sendable)
        let conformanceExt: DeclSyntax = """
            extension \(type.trimmed): Persistable, Codable, Sendable {}
            """

        if let extensionDecl = conformanceExt.as(ExtensionDeclSyntax.self) {
            return [extensionDecl]
        }

        return []
    }
}

/// Primary key macro
///
/// **Usage**:
/// ```swift
/// #PrimaryKey<User>([\.userID])
/// #PrimaryKey<User>([\.country, \.userID])  // Composite key
/// ```
///
/// This is a marker macro. Validation is performed, but no code is generated.
/// The @Persistable macro detects #PrimaryKey calls and extracts KeyPaths.
public struct PrimaryKeyMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Validate generic type parameter
        guard let genericClause = node.genericArgumentClause,
              let _ = genericClause.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#PrimaryKey requires a type parameter (e.g., #PrimaryKey<User>)")
                )
            ])
        }

        // Validate first argument is an array of KeyPaths
        guard let firstArg = node.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#PrimaryKey requires an array of KeyPaths (e.g., [\\.$userID])")
                )
            ])
        }

        guard let _ = firstArg.expression.as(ArrayExprSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(firstArg.expression),
                    message: MacroExpansionErrorMessage("Primary key must be specified as an array of KeyPaths (e.g., [\\.$userID])")
                )
            ])
        }

        // Marker macro - no code generation
        return []
    }
}

/// Index macro
///
/// **Usage**:
/// ```swift
/// #Index<User>([\.email], type: ScalarIndexKind(), unique: true)
/// #Index<User>([\.country, \.city], type: ScalarIndexKind())
/// #Index<User>([\.embedding], type: VectorIndexKind(dimensions: 384))
/// ```
///
/// This is a marker macro. Validation is performed, but no code is generated.
/// The @Persistable macro detects #Index calls and generates IndexDescriptor array.
public struct IndexMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Validate generic type parameter
        guard let genericClause = node.genericArgumentClause,
              let _ = genericClause.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Index requires a type parameter (e.g., #Index<User>)")
                )
            ])
        }

        // Validate first argument is an array of KeyPaths
        guard let firstArg = node.arguments.first else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(node),
                    message: MacroExpansionErrorMessage("#Index requires an array of KeyPaths (e.g., [\\.$email])")
                )
            ])
        }

        guard let _ = firstArg.expression.as(ArrayExprSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: Syntax(firstArg.expression),
                    message: MacroExpansionErrorMessage("Index fields must be specified as an array of KeyPaths (e.g., [\\.$email])")
                )
            ])
        }

        // Marker macro - no code generation
        return []
    }
}

/// Compiler plugin entry point
@main
struct FDBCoreMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        PersistableMacro.self,
        PrimaryKeyMacro.self,
        IndexMacro.self,
        DirectoryMacro.self,
    ]
}

/// Error message helper
struct MacroExpansionErrorMessage: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ message: String) {
        self.message = message
        self.diagnosticID = MessageID(domain: "FDBCoreMacros", id: message)
        self.severity = .error
    }
}
