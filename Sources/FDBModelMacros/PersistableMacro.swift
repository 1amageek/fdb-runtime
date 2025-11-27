import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// @Persistable macro implementation
///
/// Generates Persistable protocol conformance with metadata methods and ID management.
///
/// **Supports all layers**:
/// - RecordLayer (RDB): Structured records with indexes
/// - DocumentLayer (DocumentDB): Flexible documents
/// - GraphLayer (GraphDB): Define nodes with relationships
///
/// **Generated code includes**:
/// - `var id: String = ULID().ulidString` (if not user-defined)
/// - `static var persistableType: String`
/// - `static var allFields: [String]`
/// - `static var indexDescriptors: [IndexDescriptor]`
/// - `static func fieldNumber(for fieldName: String) -> Int?`
/// - `static func enumMetadata(for fieldName: String) -> EnumMetadata?`
/// - `init(...)` (without `id` parameter)
///
/// **ID Behavior**:
/// - If user defines `id` field: uses that type and default value
/// - If user omits `id` field: macro adds `var id: String = ULID().ulidString`
/// - `id` is NOT included in the generated initializer
///
/// **Usage**:
/// ```swift
/// @Persistable
/// struct User {
///     #Index<User>([\.email], unique: true)
///
///     var email: String
///     var name: String
/// }
/// ```
///
/// **With custom type name**:
/// ```swift
/// @Persistable(type: "User")
/// struct Member {
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

        let structName = structDecl.name.text

        // Extract custom type name from macro argument if provided
        let typeName: String
        if let arguments = node.arguments,
           let labeledList = arguments.as(LabeledExprListSyntax.self),
           let firstArg = labeledList.first,
           firstArg.label?.text == "type",
           let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self),
           let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            typeName = segment.content.text
        } else {
            typeName = structName
        }

        // Check if user defined `id` field
        var hasUserDefinedId = false
        var userIdHasDefault = false
        var userIdBinding: PatternBindingSyntax?

        // Extract all stored properties (fields)
        var allFields: [String] = []
        var fieldInfos: [(name: String, type: String, hasDefault: Bool, defaultValue: String?)] = []
        var fieldNumber = 1

        for member in structDecl.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                let isVar = varDecl.bindingSpecifier.text == "var"
                let isLet = varDecl.bindingSpecifier.text == "let"

                if isVar || isLet {
                    for binding in varDecl.bindings {
                        if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                            let fieldName = pattern.identifier.text
                            let fieldType = binding.typeAnnotation?.type.description.trimmingCharacters(in: .whitespaces) ?? "Any"
                            let hasDefault = binding.initializer != nil
                            let defaultValue = binding.initializer?.value.description.trimmingCharacters(in: .whitespaces)

                            if fieldName == "id" {
                                hasUserDefinedId = true
                                userIdHasDefault = hasDefault
                                userIdBinding = binding
                            }

                            allFields.append(fieldName)
                            fieldInfos.append((name: fieldName, type: fieldType, hasDefault: hasDefault, defaultValue: defaultValue))
                            fieldNumber += 1
                        }
                    }
                }
            }
        }

        // Validate: User-defined id MUST have a default value
        // Because id is excluded from the generated initializer
        if hasUserDefinedId && !userIdHasDefault {
            let diagnosticNode: Syntax
            if let binding = userIdBinding {
                diagnosticNode = Syntax(binding)
            } else {
                diagnosticNode = Syntax(node)
            }
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: diagnosticNode,
                    message: MacroExpansionErrorMessage(
                        "User-defined 'id' field must have a default value. " +
                        "The generated initializer does not include 'id' parameter. " +
                        "Example: var id: UUID = UUID() or var id: Int64 = Int64(Date().timeIntervalSince1970 * 1000)"
                    )
                )
            ])
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

        var decls: [DeclSyntax] = []

        // Generate `id` field if not user-defined
        if !hasUserDefinedId {
            let idDecl: DeclSyntax = """
                public var id: String = ULID().ulidString
                """
            decls.append(idDecl)

            // Add id to allFields at the beginning
            allFields.insert("id", at: 0)
            fieldInfos.insert((name: "id", type: "String", hasDefault: true, defaultValue: "ULID().ulidString"), at: 0)
        }

        // Generate persistableType property
        let persistableTypeDecl: DeclSyntax = """
            public static var persistableType: String { "\(raw: typeName)" }
            """
        decls.append(persistableTypeDecl)

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
        for (index, fieldInfo) in fieldInfos.enumerated() {
            fieldNumberCases.append("case \"\(fieldInfo.name)\": return \(index + 1)")
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

        // Generate subscript for @dynamicMemberLookup
        var subscriptCases: [String] = []
        for fieldInfo in fieldInfos {
            subscriptCases.append("case \"\(fieldInfo.name)\": return self.\(fieldInfo.name)")
        }
        let subscriptBody = subscriptCases.isEmpty
            ? "return nil"
            : """
            switch member {
                    \(subscriptCases.joined(separator: "\n        "))
                    default: return nil
                }
            """
        let subscriptDecl: DeclSyntax = """
            public subscript(dynamicMember member: String) -> (any Sendable)? {
                \(raw: subscriptBody)
            }
            """
        decls.append(subscriptDecl)

        // Generate init without `id` parameter
        // Only include fields that are NOT `id`
        let initParams = fieldInfos
            .filter { $0.name != "id" }
            .map { info -> String in
                if info.hasDefault, let defaultValue = info.defaultValue {
                    return "\(info.name): \(info.type) = \(defaultValue)"
                } else {
                    return "\(info.name): \(info.type)"
                }
            }
            .joined(separator: ", ")

        let initAssignments = fieldInfos
            .filter { $0.name != "id" }
            .map { "self.\($0.name) = \($0.name)" }
            .joined(separator: "\n        ")

        if !initAssignments.isEmpty {
            let initDecl: DeclSyntax = """
                public init(\(raw: initParams)) {
                    \(raw: initAssignments)
                }
                """
            decls.append(initDecl)
        } else {
            // No fields other than id
            let initDecl: DeclSyntax = """
                public init() {}
                """
            decls.append(initDecl)
        }

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

/// Index macro
///
/// **Usage**:
/// ```swift
/// #Index<User>([\.email], type: ScalarIndexKind(), unique: true)
/// #Index<User>([\.country, \.city], type: ScalarIndexKind())
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
struct FDBModelMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        PersistableMacro.self,
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
        self.diagnosticID = MessageID(domain: "FDBModelMacros", id: message)
        self.severity = .error
    }
}
