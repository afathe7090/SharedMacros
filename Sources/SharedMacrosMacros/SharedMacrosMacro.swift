import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Implementation of the `stringify` macro, which takes an expression
/// of any type and produces a tuple containing the value of that expression
/// and the source code that produced the value. For example
///
///     #stringify(x + y)
///
///  will expand to
///
///     (x + y, "x + y")
public struct StringifyMacro: ExpressionMacro {
  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) -> ExprSyntax {
    guard let argument = node.arguments.first?.expression else {
      fatalError("compiler bug: the macro does not have any arguments")
    }

    return "(\(argument), \(literal: argument.description))"
  }
}

/// Implementation of the `@Setable` macro
public struct SetableMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // Determine if this is a struct or class
    let isStruct: Bool
    let typeName: String
        
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      isStruct = true
      typeName = structDecl.name.text
    } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
      isStruct = false
      typeName = classDecl.name.text
    } else {
      // @Setable can only be applied to structs or classes
      return []
    }
        
    // Extract all variable declarations
    let members = declaration.memberBlock.members
    var variableDecls: [(name: String, type: String)] = []
        
    for member in members {
      if let variableDecl = member.decl.as(VariableDeclSyntax.self),
         variableDecl.bindingSpecifier.text == "var"
      {
        for binding in variableDecl.bindings {
          if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
             let typeAnnotation = binding.typeAnnotation
          {
            let varName = pattern.identifier.text
            let varType = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
            variableDecls.append((name: varName, type: varType))
          }
        }
      }
    }
        
    var declarations: [DeclSyntax] = []
        
    // Add Builder typealias
    if isStruct {
      declarations.append("typealias Builder = (Self) -> Self")
    } else {
      declarations.append("typealias Builder = (\(raw: typeName)) -> \(raw: typeName)")
    }
        
    // Generate setter methods for each variable
    for variable in variableDecls {
      let capitalizedName = variable.name.prefix(1).uppercased() + variable.name.dropFirst()
      let methodName = "set\(capitalizedName)"
            
      if isStruct {
        // Struct setter: creates a copy, modifies it, and returns it
        let setterMethod: DeclSyntax = """
        @discardableResult
        func \(raw: methodName)(_ \(raw: variable.name): \(raw: variable.type)) -> Self {
          var copy = self
          copy.\(raw: variable.name) = \(raw: variable.name)
          return copy
        }
        """
        declarations.append(setterMethod)
      } else {
        // Class setter: modifies self and returns it
        let setterMethod: DeclSyntax = """
        @discardableResult
        func \(raw: methodName)(_ \(raw: variable.name): \(raw: variable.type)) -> Self {
          self.\(raw: variable.name) = \(raw: variable.name)
          return self
        }
        """
        declarations.append(setterMethod)
      }
    }
        
    return declarations
  }
}

/// Implementation of the `@MockData` macro
public struct MockDataMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // Determine the type name
    let typeName: String
        
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      typeName = structDecl.name.text
    } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
      typeName = classDecl.name.text
    } else {
      // @MockData can only be applied to structs or classes
      return []
    }
        
    // Extract all variable declarations (both var and let)
    let members = declaration.memberBlock.members
    var variableDecls: [(name: String, type: String)] = []
        
    for member in members {
      if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
        // Accept both "var" and "let" properties
        let bindingType = variableDecl.bindingSpecifier.text
        if bindingType == "var" || bindingType == "let" {
          for binding in variableDecl.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
               let typeAnnotation = binding.typeAnnotation
            {
              let varName = pattern.identifier.text
              let varType = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
              variableDecls.append((name: varName, type: varType))
            }
          }
        }
      }
    }
        
    var declarations: [DeclSyntax] = []
        
    // Generate mock() static function
    let mockArguments = variableDecls.map { variable in
      let mockValue = generateMockValue(for: variable.type)
      return "\(variable.name): \(mockValue)"
    }.joined(separator: ", ")
        
    let mockMethod: DeclSyntax = """
    static func mock() -> \(raw: typeName) {
      \(raw: typeName)(\(raw: mockArguments))
    }
    """
    declarations.append(mockMethod)
        
    // Generate preview static property
    let previewArguments = variableDecls.map { variable in
      let previewValue = generatePreviewValue(for: variable.type)
      return "\(variable.name): \(previewValue)"
    }.joined(separator: ", ")
        
    let previewProperty: DeclSyntax = """
    static var preview: \(raw: typeName) {
      \(raw: typeName)(\(raw: previewArguments))
    }
    """
    declarations.append(previewProperty)
        
    return declarations
  }
    
  /// Generates appropriate mock values based on the type
  private static func generateMockValue(for type: String) -> String {
    let trimmedType = type.trimmingCharacters(in: .whitespaces)
        
    // Handle optional types
    if trimmedType.hasSuffix("?") {
      let nonOptionalType = String(trimmedType.dropLast()).trimmingCharacters(in: .whitespaces)
      return generateMockValue(for: nonOptionalType)
    }
        
    // Handle arrays
    if trimmedType.hasPrefix("[") && trimmedType.hasSuffix("]") {
      return "[]"
    }
        
    // Handle dictionaries
    if trimmedType.hasPrefix("[") && trimmedType.contains(":") {
      return "[:]"
    }
        
    // Handle specific types
    switch trimmedType.lowercased() {
    case "string":
      return "\"Mock \(String.randomString(length: 8))\""
    case "int":
      return "\(Int.random(in: 1...100))"
    case "double", "float":
      return "\(Double.random(in: 1.0...100.0))"
    case "bool", "boolean":
      return "true"
    case "date":
      return "Date()"
    case "data":
      return "Data()"
    case "url":
      return "URL(string: \"https://example.com\")!"
    default:
      // For custom types, try to call their mock() method if available
      if trimmedType.contains(".") {
        return "\(trimmedType).mock()"
      } else {
        return "\(trimmedType).mock()"
      }
    }
  }
    
  /// Generates appropriate preview values based on the type
  private static func generatePreviewValue(for type: String) -> String {
    let trimmedType = type.trimmingCharacters(in: .whitespaces)
        
    // Handle optional types
    if trimmedType.hasSuffix("?") {
      let nonOptionalType = String(trimmedType.dropLast()).trimmingCharacters(in: .whitespaces)
      return generatePreviewValue(for: nonOptionalType)
    }
        
    // Handle arrays
    if trimmedType.hasPrefix("[") && trimmedType.hasSuffix("]") {
      return "[]"
    }
        
    // Handle dictionaries
    if trimmedType.hasPrefix("[") && trimmedType.contains(":") {
      return "[:]"
    }
        
    // Handle specific types
    switch trimmedType.lowercased() {
    case "string":
      return "\"Preview \(String.randomString(length: 8))\""
    case "int":
      return "\(Int.random(in: 18...65))"
    case "double", "float":
      return "\(Double.random(in: 1.0...100.0))"
    case "bool", "boolean":
      return "false"
    case "date":
      return "Date().addingTimeInterval(-86400)" // Yesterday
    case "data":
      return "Data()"
    case "url":
      return "URL(string: \"https://preview.example.com\")!"
    default:
      // For custom types, try to call their preview property if available
      if trimmedType.contains(".") {
        return "\(trimmedType).preview"
      } else {
        return "\(trimmedType).preview"
      }
    }
  }
}

// Extension to generate random strings
extension String {
  static func randomString(length: Int) -> String {
    let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return String((0 ..< length).map { _ in letters.randomElement()! })
  }
}

/// Implementation of the `@Spy` macro
public struct SpyMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    
    // Check if it's a protocol
    if let protocolDecl = declaration.as(ProtocolDeclSyntax.self) {
      return try generateProtocolSpy(protocolDecl: protocolDecl)
    }
    
    // Check if it's a class
    if let classDecl = declaration.as(ClassDeclSyntax.self) {
      return try generateClassSpy(classDecl: classDecl)
    }
    
    // Check if it's a struct
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      return try generateStructSpy(structDecl: structDecl)
    }
    
    return []
  }
  
  // Helper to generate PropertyInfo from var decl
  private static func parseProperties(from members: MemberBlockItemListSyntax) -> [PropertyInfo] {
    var properties: [PropertyInfo] = []
    
    for member in members {
      if let varDecl = member.decl.as(VariableDeclSyntax.self),
         varDecl.bindingSpecifier.text == "var" {
        for binding in varDecl.bindings {
          if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
             let typeAnnotation = binding.typeAnnotation {
            let propName = pattern.identifier.text
            let propType = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
            properties.append(PropertyInfo(name: propName, type: propType))
          }
        }
      }
    }
    
    return properties
  }
  
  // Generate spy for protocol
  private static func generateProtocolSpy(protocolDecl: ProtocolDeclSyntax) throws -> [DeclSyntax] {
    let protocolName = protocolDecl.name.text
    let spyClassName = "\(protocolName)Spy"
    
    // Extract function and property declarations from protocol
    let members = protocolDecl.memberBlock.members
    var methods: [MethodInfo] = []
    var properties: [ProtocolPropertyInfo] = []
    
    for member in members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
        let methodInfo = parseMethod(funcDecl)
        methods.append(methodInfo)
      } else if let varDecl = member.decl.as(VariableDeclSyntax.self) {
        // Parse protocol property requirements
        for binding in varDecl.bindings {
          if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
             let typeAnnotation = binding.typeAnnotation {
            let propName = pattern.identifier.text
            let propType = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
            
            // Check if it has getter/setter
            var isReadOnly = true
            if let accessor = binding.accessorBlock {
              let accessorText = accessor.description
              if accessorText.contains("set") || accessorText.contains("{ get set }") {
                isReadOnly = false
              }
            }
            
            properties.append(ProtocolPropertyInfo(name: propName, type: propType, isReadOnly: isReadOnly))
          }
        }
      }
    }
    
    // Generate the complete spy class with properties
    let spyClass = generateCompleteSpyClassWithProtocolProperties(
      className: spyClassName,
      protocolName: protocolName,
      methods: methods,
      properties: properties,
      initializers: [],
      isSubclass: false
    )
    
    // Note: Can't generate namespace enum with same name as protocol
    // Users should use ProtocolNameSpy() directly for protocols
    
    return [spyClass]
  }
  
  // Generate spy for class
  private static func generateClassSpy(classDecl: ClassDeclSyntax) throws -> [DeclSyntax] {
    let className = classDecl.name.text
    let spyClassName = "\(className)Spy"
    
    let members = classDecl.memberBlock.members
    var methods: [MethodInfo] = []
    var initializers: [InitializerInfo] = []
    var publishedProperties: [PublishedPropertyInfo] = []
    
    for member in members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
        let methodInfo = parseMethod(funcDecl)
        methods.append(methodInfo)
      } else if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
        let initInfo = parseInitializer(initDecl)
        initializers.append(initInfo)
      } else if let varDecl = member.decl.as(VariableDeclSyntax.self) {
        // Check for @Published properties
        for attribute in varDecl.attributes {
          if let attr = attribute.as(AttributeSyntax.self),
             attr.attributeName.description.trimmingCharacters(in: .whitespaces) == "Published" {
            for binding in varDecl.bindings {
              if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                 let typeAnnotation = binding.typeAnnotation {
                let propName = pattern.identifier.text
                let propType = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
                publishedProperties.append(PublishedPropertyInfo(name: propName, type: propType))
              }
            }
          }
        }
      }
    }
    
    // Generate spy class that inherits from the original class
    let spyClass = generateCompleteSpyClassWithProperties(
      className: spyClassName,
      protocolName: className, // Inherit from original class
      methods: methods,
      initializers: initializers,
      publishedProperties: publishedProperties,
      isSubclass: true
    )
    
    return [spyClass]
  }
  
  // Generate spy for struct
  private static func generateStructSpy(structDecl: StructDeclSyntax) throws -> [DeclSyntax] {
    let structName = structDecl.name.text
    let spyClassName = "\(structName)Spy"
    
    let members = structDecl.memberBlock.members
    var methods: [MethodInfo] = []
    var properties: [PropertyInfo] = []
    
    for member in members {
      if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
        let methodInfo = parseMethod(funcDecl)
        methods.append(methodInfo)
      } else if let varDecl = member.decl.as(VariableDeclSyntax.self),
                varDecl.bindingSpecifier.text == "var" {
        for binding in varDecl.bindings {
          if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
             let typeAnnotation = binding.typeAnnotation {
            let propName = pattern.identifier.text
            let propType = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
            properties.append(PropertyInfo(name: propName, type: propType))
          }
        }
      }
    }
    
    // Generate wrapper spy for struct
    let spyClass = generateStructSpyClass(
      className: spyClassName,
      structName: structName,
      methods: methods,
      properties: properties
    )
    
    return [spyClass]
  }
  
  // Generate complete spy class
  private static func generateCompleteSpyClass(
    className: String,
    protocolName: String,
    methods: [MethodInfo],
    initializers: [InitializerInfo],
    isSubclass: Bool
  ) -> DeclSyntax {
    var classBody: [String] = []
    
    // Generate State enum
    classBody.append(generateStateEnumString(methods: methods))
    
    // Generate states tracking
    classBody.append("  private(set) var states: [State] = []")
    classBody.append("  var callCount: Int { states.count }")
    classBody.append("")
    
    // Generate initializers
    if !initializers.isEmpty {
      for initializer in initializers {
        classBody.append(generateInitializerString(initializer: initializer, isSubclass: isSubclass))
      }
    } else if !isSubclass {
      // Default init for protocols
      classBody.append("  init() {}")
      classBody.append("")
    }
    
    // Generate storage and simulation helpers for each method
    for method in methods {
      classBody.append(contentsOf: generateMethodStorageStrings(method: method))
    }
    
    // Generate protocol method implementations
    for method in methods {
      classBody.append(generateMethodImplementationString(method: method, isOverride: isSubclass))
    }
    
    // Generate simulation helper methods
    for method in methods {
      classBody.append(contentsOf: generateSimulationHelperStrings(method: method))
    }
    
    // Generate utility methods
    classBody.append("")
    classBody.append("  func reset() {")
    classBody.append("    states.removeAll()")
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func didCall(_ state: State) -> Bool {")
    classBody.append("    states.contains(state)")
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func callCount(for state: State) -> Int {")
    classBody.append("    states.filter { $0 == state }.count")
    classBody.append("  }")
    
    let classContent = classBody.joined(separator: "\n")
    
    let inheritance = protocolName.isEmpty ? "" : ": \(protocolName)"
    
    return """
    final class \(raw: className)\(raw: inheritance) {
    \(raw: classContent)
    }
    """
  }
  
  // Generate complete spy class with @Published property tracking
  private static func generateCompleteSpyClassWithProperties(
    className: String,
    protocolName: String,
    methods: [MethodInfo],
    initializers: [InitializerInfo],
    publishedProperties: [PublishedPropertyInfo],
    isSubclass: Bool
  ) -> DeclSyntax {
    var classBody: [String] = []
    
    // Generate State enum
    classBody.append(generateStateEnumString(methods: methods))
    
    // Generate states tracking
    classBody.append("  private(set) var states: [State] = []")
    classBody.append("  var callCount: Int { states.count }")
    classBody.append("")
    
    // Generate @Published property tracking storage
    if !publishedProperties.isEmpty {
      classBody.append("  // @Published property tracking")
      classBody.append("  private var publishedCancellables = Set<AnyCancellable>()")
      for property in publishedProperties {
        classBody.append("  private(set) var \(property.name)ReceivedValues: [\(property.type)] = []")
      }
      classBody.append("")
    }
    
    // Generate initializers with @Published subscriptions
    if !initializers.isEmpty {
      for initializer in initializers {
        classBody.append(generateInitializerStringWithPublishedTracking(
          initializer: initializer,
          publishedProperties: publishedProperties,
          isSubclass: isSubclass
        ))
      }
    } else if !isSubclass {
      // Default init for protocols
      classBody.append("  init() {}")
      classBody.append("")
    }
    
    // Generate storage and simulation helpers for each method
    for method in methods {
      classBody.append(contentsOf: generateMethodStorageStrings(method: method))
    }
    
    // Generate protocol method implementations
    for method in methods {
      classBody.append(generateMethodImplementationString(method: method, isOverride: isSubclass))
    }
    
    // Generate simulation helper methods
    for method in methods {
      classBody.append(contentsOf: generateSimulationHelperStrings(method: method))
    }
    
    // Generate utility methods
    classBody.append("")
    classBody.append("  func reset() {")
    classBody.append("    states.removeAll()")
    for property in publishedProperties {
      classBody.append("    \(property.name)ReceivedValues.removeAll()")
    }
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func didCall(_ state: State) -> Bool {")
    classBody.append("    states.contains(state)")
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func callCount(for state: State) -> Int {")
    classBody.append("    states.filter { $0 == state }.count")
    classBody.append("  }")
    
    let classContent = classBody.joined(separator: "\n")
    
    let inheritance = protocolName.isEmpty ? "" : ": \(protocolName)"
    
    return """
    final class \(raw: className)\(raw: inheritance) {
    \(raw: classContent)
    }
    """
  }
  
  // Generate initializer with @Published property tracking
  private static func generateInitializerStringWithPublishedTracking(
    initializer: InitializerInfo,
    publishedProperties: [PublishedPropertyInfo],
    isSubclass: Bool
  ) -> String {
    // Build parameter list with external labels
    let params = initializer.parameters.map { param in
      if let externalName = param.externalName {
        // Only include external name if different from internal name
        if externalName == param.name {
          return "\(param.name): \(param.type)"
        } else {
          return "\(externalName) \(param.name): \(param.type)"
        }
      } else {
        return "_ \(param.name): \(param.type)"
      }
    }.joined(separator: ", ")
    
    let throwsKeyword = initializer.isThrowing ? " throws" : ""
    let overrideKeyword = isSubclass ? "override " : ""
    
    if isSubclass {
      // Build super.init call arguments
      let superArgs = initializer.parameters.map { param in
        if let externalName = param.externalName {
          return "\(externalName): \(param.name)"
        } else {
          return "\(param.name)"
        }
      }.joined(separator: ", ")
      
      var initBody = """
        \(overrideKeyword)init(\(params))\(throwsKeyword) {
          \(initializer.isThrowing ? "try " : "")super.init(\(superArgs))
      
      """
      
      // Add @Published property subscriptions
      if !publishedProperties.isEmpty {
        initBody += "    // Auto-track @Published properties\n"
        for property in publishedProperties {
          initBody += """
              $\(property.name)
                .sink { [weak self] value in
                  self?.\(property.name)ReceivedValues.append(value)
                }
                .store(in: &publishedCancellables)
          
          """
        }
      }
      
      initBody += "  }\n\n"
      return initBody
    } else {
      var initBody = """
        init(\(params))\(throwsKeyword) {
      
      """
      
      // Add @Published property subscriptions
      if !publishedProperties.isEmpty {
        initBody += "    // Auto-track @Published properties\n"
        for property in publishedProperties {
          initBody += """
              $\(property.name)
                .sink { [weak self] value in
                  self?.\(property.name)ReceivedValues.append(value)
                }
                .store(in: &publishedCancellables)
          
          """
        }
      }
      
      initBody += "  }\n\n"
      return initBody
    }
  }
  
  // Generate complete spy class with protocol properties
  private static func generateCompleteSpyClassWithProtocolProperties(
    className: String,
    protocolName: String,
    methods: [MethodInfo],
    properties: [ProtocolPropertyInfo],
    initializers: [InitializerInfo],
    isSubclass: Bool
  ) -> DeclSyntax {
    var classBody: [String] = []
    
    // Generate State enum
    classBody.append(generateStateEnumString(methods: methods))
    
    // Generate states tracking
    classBody.append("  private(set) var states: [State] = []")
    classBody.append("  var callCount: Int { states.count }")
    classBody.append("")
    
    // Generate protocol property implementations
    if !properties.isEmpty {
      classBody.append("  // Protocol property implementations")
      for property in properties {
        if property.isReadOnly {
          // Read-only property
          classBody.append("  var \(property.name): \(property.type)")
        } else {
          // Read-write property with tracking
          classBody.append("  var \(property.name): \(property.type) {")
          classBody.append("    didSet {")
          classBody.append("      \(property.name)SetCount += 1")
          classBody.append("      \(property.name)ReceivedValues.append(\(property.name))")
          classBody.append("    }")
          classBody.append("  }")
          classBody.append("  private(set) var \(property.name)SetCount: Int = 0")
          classBody.append("  private(set) var \(property.name)ReceivedValues: [\(property.type)] = []")
        }
      }
      classBody.append("")
    }
    
    // Generate initializers
    if !initializers.isEmpty {
      for initializer in initializers {
        classBody.append(generateInitializerString(initializer: initializer, isSubclass: isSubclass))
      }
    } else {
      // Default init with property parameters
      if !properties.isEmpty {
        let params = properties.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        let assignments = properties.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n    ")
        classBody.append("  init(\(params)) {")
        classBody.append("    \(assignments)")
        classBody.append("  }")
      } else {
        classBody.append("  init() {}")
      }
      classBody.append("")
    }
    
    // Generate storage and simulation helpers for each method
    for method in methods {
      classBody.append(contentsOf: generateMethodStorageStrings(method: method))
    }
    
    // Generate protocol method implementations
    for method in methods {
      classBody.append(generateMethodImplementationString(method: method, isOverride: isSubclass))
    }
    
    // Generate simulation helper methods
    for method in methods {
      classBody.append(contentsOf: generateSimulationHelperStrings(method: method))
    }
    
    // Generate utility methods
    classBody.append("")
    classBody.append("  func reset() {")
    classBody.append("    states.removeAll()")
    for property in properties where !property.isReadOnly {
      classBody.append("    \(property.name)SetCount = 0")
      classBody.append("    \(property.name)ReceivedValues.removeAll()")
    }
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func didCall(_ state: State) -> Bool {")
    classBody.append("    states.contains(state)")
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func callCount(for state: State) -> Int {")
    classBody.append("    states.filter { $0 == state }.count")
    classBody.append("  }")
    
    let classContent = classBody.joined(separator: "\n")
    
    let inheritance = protocolName.isEmpty ? "" : ": \(protocolName)"
    
    return """
    final class \(raw: className)\(raw: inheritance) {
    \(raw: classContent)
    }
    """
  }
  
  // Generate struct spy class (wrapper pattern)
  private static func generateStructSpyClass(
    className: String,
    structName: String,
    methods: [MethodInfo],
    properties: [PropertyInfo]
  ) -> DeclSyntax {
    var classBody: [String] = []
    
    // Generate State enum
    classBody.append(generateStateEnumString(methods: methods))
    
    // Generate states tracking
    classBody.append("  private(set) var states: [State] = []")
    classBody.append("  var callCount: Int { states.count }")
    classBody.append("")
    
    // Generate wrapped properties
    for prop in properties {
      classBody.append("  var \(prop.name): \(prop.type)")
    }
    classBody.append("")
    
    // Generate initializer that matches struct
    if !properties.isEmpty {
      let params = properties.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
      classBody.append("  init(\(params)) {")
      for prop in properties {
        classBody.append("    self.\(prop.name) = \(prop.name)")
      }
      classBody.append("  }")
      classBody.append("")
    } else {
      classBody.append("  init() {}")
      classBody.append("")
    }
    
    // Generate storage and simulation helpers for each method
    for method in methods {
      classBody.append(contentsOf: generateMethodStorageStrings(method: method))
    }
    
    // Generate method implementations
    for method in methods {
      classBody.append(generateMethodImplementationString(method: method, isOverride: false))
    }
    
    // Generate simulation helper methods
    for method in methods {
      classBody.append(contentsOf: generateSimulationHelperStrings(method: method))
    }
    
    // Generate utility methods
    classBody.append("")
    classBody.append("  func reset() {")
    classBody.append("    states.removeAll()")
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func didCall(_ state: State) -> Bool {")
    classBody.append("    states.contains(state)")
    classBody.append("  }")
    classBody.append("")
    classBody.append("  func callCount(for state: State) -> Int {")
    classBody.append("    states.filter { $0 == state }.count")
    classBody.append("  }")
    
    let classContent = classBody.joined(separator: "\n")
    
    return """
    final class \(raw: className) {
    \(raw: classContent)
    }
    """
  }
  
  // Parse initializer
  private static func parseInitializer(_ initDecl: InitializerDeclSyntax) -> InitializerInfo {
    var parameters: [ParameterInfo] = []
    var isThrowing = false
    
    // Check if throwing
    if let signature = initDecl.signature.effectSpecifiers {
      isThrowing = signature.throwsClause != nil
    }
    
    // Parse parameters
    for param in initDecl.signature.parameterClause.parameters {
      let externalName = param.firstName.text
      let internalName = param.secondName?.text ?? param.firstName.text
      let paramType = param.type.description.trimmingCharacters(in: .whitespaces)
      parameters.append(ParameterInfo(
        name: internalName,
        type: paramType,
        externalName: externalName == "_" ? nil : externalName
      ))
    }
    
    return InitializerInfo(parameters: parameters, isThrowing: isThrowing)
  }
  
  // Generate initializer string
  private static func generateInitializerString(initializer: InitializerInfo, isSubclass: Bool) -> String {
    // Build parameter list with external labels
    let params = initializer.parameters.map { param in
      if let externalName = param.externalName {
        // Only include external name if different from internal name
        if externalName == param.name {
          return "\(param.name): \(param.type)"
        } else {
          return "\(externalName) \(param.name): \(param.type)"
        }
      } else {
        return "_ \(param.name): \(param.type)"
      }
    }.joined(separator: ", ")
    
    let throwsKeyword = initializer.isThrowing ? " throws" : ""
    
    if isSubclass {
      // Build super.init call arguments
      let superArgs = initializer.parameters.map { param in
        if let externalName = param.externalName {
          return "\(externalName): \(param.name)"
        } else {
          return "\(param.name)"
        }
      }.joined(separator: ", ")
      
      return """
        override init(\(params))\(throwsKeyword) {
          \(initializer.isThrowing ? "try " : "")super.init(\(superArgs))
        }
      
      """
    } else {
      return """
        init(\(params))\(throwsKeyword) {}
      
      """
    }
  }
  
  // Parse method information
  private static func parseMethod(_ funcDecl: FunctionDeclSyntax) -> MethodInfo {
    let methodName = funcDecl.name.text
    var parameters: [ParameterInfo] = []
    var returnType: String = "Void"
    var isAsync = false
    var isThrowing = false
    var completionParam: ParameterInfo?
    var isPrivate = false
    
    // Check for private modifier
    for modifier in funcDecl.modifiers {
      if modifier.name.text == "private" {
        isPrivate = true
        break
      }
    }
    
    // Check if async/throws
    if let signature = funcDecl.signature.effectSpecifiers {
      isAsync = signature.asyncSpecifier != nil
      isThrowing = signature.throwsClause != nil
    }
    
    // Parse parameters
    for param in funcDecl.signature.parameterClause.parameters {
      let externalName = param.firstName.text
      let internalName = param.secondName?.text ?? param.firstName.text
      let paramType = param.type.description.trimmingCharacters(in: .whitespaces)
      
      // Use internal name for the parameter, but track external for call sites
      let paramInfo = ParameterInfo(
        name: internalName,
        type: paramType,
        externalName: externalName == "_" ? nil : externalName
      )
      
      // Check if this is a completion handler
      if paramType.contains("@escaping") && paramType.contains("->") {
        completionParam = paramInfo
      } else {
        parameters.append(paramInfo)
      }
    }
    
    // Parse return type
    if let returnClause = funcDecl.signature.returnClause {
      returnType = returnClause.type.description.trimmingCharacters(in: .whitespaces)
    }
    
    return MethodInfo(
      name: methodName,
      parameters: parameters,
      returnType: returnType,
      isAsync: isAsync,
      isThrowing: isThrowing,
      completionParam: completionParam,
      isPrivate: isPrivate
    )
  }
  
  // Generate State enum as string
  private static func generateStateEnumString(methods: [MethodInfo]) -> String {
    var enumCases: [String] = []
    var equalityCases: [String] = []
    
    for method in methods {
      if method.parameters.isEmpty {
        enumCases.append("    case \(method.name)")
        equalityCases.append("      case (.\(method.name), .\(method.name)): return true")
      } else {
        let params = method.parameters.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        enumCases.append("    case \(method.name)(\(params))")
        
        let lhsParams = method.parameters.map { "let lhs\($0.name.prefix(1).uppercased() + $0.name.dropFirst())" }.joined(separator: ", ")
        let rhsParams = method.parameters.map { "let rhs\($0.name.prefix(1).uppercased() + $0.name.dropFirst())" }.joined(separator: ", ")
        let comparisons = method.parameters.map { "lhs\($0.name.prefix(1).uppercased() + $0.name.dropFirst()) == rhs\($0.name.prefix(1).uppercased() + $0.name.dropFirst())" }.joined(separator: " && ")
        
        equalityCases.append("      case (.\(method.name)(\(lhsParams)), .\(method.name)(\(rhsParams))): return \(comparisons)")
      }
    }
    
    equalityCases.append("      default: return false")
    
    return """
      enum State: Equatable {
    \(enumCases.joined(separator: "\n"))
        
        static func == (lhs: State, rhs: State) -> Bool {
          switch (lhs, rhs) {
    \(equalityCases.joined(separator: "\n"))
          }
        }
      }
    """
  }
  
  // Generate method storage (completions, continuations, subjects)
  private static func generateMethodStorageStrings(method: MethodInfo) -> [String] {
    var storage: [String] = []
    
    if method.completionParam != nil {
      // Remove @escaping from the type for storage
      let completionType = method.completionParam!.type.replacingOccurrences(of: "@escaping ", with: "")
      storage.append("  private var \(method.name)Completions: [\(completionType)] = []")
      
      // Add automatic result tracking for Result types
      if method.completionParam!.type.contains("Result<") {
        let successType = extractResultSuccessType(from: method.completionParam!.type)
        let errorType = extractResultErrorType(from: method.completionParam!.type)
        storage.append("  private(set) var \(method.name)ReceivedResults: [Result<\(successType), \(errorType)>] = []")
      }
    } else if method.isAsync {
      if method.isThrowing {
        storage.append("  private var \(method.name)Continuations: [CheckedContinuation<\(method.returnType), Error>] = []")
      } else {
        storage.append("  private var \(method.name)Continuations: [UnsafeContinuation<\(method.returnType), Never>] = []")
      }
    } else if method.returnType.contains("AnyPublisher") {
      let (outputType, failureType) = extractPublisherTypes(from: method.returnType)
      storage.append("  private var \(method.name)Subjects: [PassthroughSubject<\(outputType), \(failureType)>] = []")
      storage.append("  var \(method.name)CallCount: Int { \(method.name)Subjects.count }")
      
      // Add automatic value/error tracking
      storage.append("  private var \(method.name)Cancellables: Set<AnyCancellable> = []")
      storage.append("  private(set) var \(method.name)ReceivedValues: [[\(outputType)]] = []")
      if failureType != "Never" {
        storage.append("  private(set) var \(method.name)ReceivedErrors: [\(failureType)] = []")
      }
    }
    
    if !storage.isEmpty {
      storage.append("")
    }
    
    return storage
  }
  
  // Generate protocol method implementation
  private static func generateMethodImplementationString(method: MethodInfo, isOverride: Bool) -> String {
    let capitalizedName = method.name.prefix(1).uppercased() + method.name.dropFirst()
    
    // Build state case
    let stateCase: String
    if method.parameters.isEmpty {
      stateCase = ".\(method.name)"
    } else {
      let params = method.parameters.map { "\($0.name): \($0.name)" }.joined(separator: ", ")
      stateCase = ".\(method.name)(\(params))"
    }
    
    // Build parameter list with proper external labels
    var paramList: [String] = []
    for param in method.parameters {
      if let externalName = param.externalName {
        // Only include external name if it's different from internal name
        if externalName == param.name {
          paramList.append("\(param.name): \(param.type)")
        } else {
          paramList.append("\(externalName) \(param.name): \(param.type)")
        }
      } else {
        paramList.append("_ \(param.name): \(param.type)")
      }
    }
    if let completion = method.completionParam {
      if let externalName = completion.externalName {
        // Only include external name if it's different from internal name
        if externalName == completion.name {
          paramList.append("\(completion.name): \(completion.type)")
        } else {
          paramList.append("\(externalName) \(completion.name): \(completion.type)")
        }
      } else {
        paramList.append("_ \(completion.name): \(completion.type)")
      }
    }
    let paramString = paramList.joined(separator: ", ")
    
    // Build signature
    // For private methods: don't override, add _private prefix
    let overrideKeyword = (isOverride && !method.isPrivate) ? "override " : ""
    let methodNameToUse = method.isPrivate ? "_private\(method.name.prefix(1).uppercased() + method.name.dropFirst())" : method.name
    var signature = "  \(overrideKeyword)func \(methodNameToUse)(\(paramString))"
    if method.isAsync {
      signature += " async"
    }
    if method.isThrowing {
      signature += " throws"
    }
    if method.returnType != "Void" {
      signature += " -> \(method.returnType)"
    }
    
    // Build body
    var body: [String] = []
    body.append("    states.append(\(stateCase))")
    
    if method.completionParam != nil {
      body.append("    \(method.name)Completions.append(\(method.completionParam!.name))")
    } else if method.isAsync {
      if method.isThrowing {
        body.append("    return try await withCheckedThrowingContinuation { continuation in")
        body.append("      \(method.name)Continuations.append(continuation)")
        body.append("    }")
      } else {
        body.append("    return await withUnsafeContinuation { continuation in")
        body.append("      \(method.name)Continuations.append(continuation)")
        body.append("    }")
      }
    } else if method.returnType.contains("AnyPublisher") {
      let (outputType, failureType) = extractPublisherTypes(from: method.returnType)
      body.append("    let subject = PassthroughSubject<\(outputType), \(failureType)>()")
      body.append("    \(method.name)Subjects.append(subject)")
      body.append("")
      body.append("    // Auto-capture values and errors")
      body.append("    var capturedValues: [\(outputType)] = []")
      body.append("    subject")
      if failureType != "Never" {
        body.append("      .sink(")
        body.append("        receiveCompletion: { [weak self] completion in")
        body.append("          if case .failure(let error) = completion {")
        body.append("            self?.\(method.name)ReceivedErrors.append(error)")
        body.append("          }")
        body.append("          self?.\(method.name)ReceivedValues.append(capturedValues)")
        body.append("        },")
        body.append("        receiveValue: { value in")
        body.append("          capturedValues.append(value)")
        body.append("        }")
        body.append("      )")
      } else {
        body.append("      .sink(")
        body.append("        receiveCompletion: { [weak self] _ in")
        body.append("          self?.\(method.name)ReceivedValues.append(capturedValues)")
        body.append("        },")
        body.append("        receiveValue: { value in")
        body.append("          capturedValues.append(value)")
        body.append("        }")
        body.append("      )")
      }
      body.append("      .store(in: &\(method.name)Cancellables)")
      body.append("")
      body.append("    return subject.eraseToAnyPublisher()")
    } else {
      // Regular method - call super if it's an override
      if isOverride && !method.isPrivate {
        // Build super call with parameters
        let superArgs = method.parameters.map { param in
          if let externalName = param.externalName {
            return "\(externalName): \(param.name)"
          } else {
            return "\(param.name)"
          }
        }.joined(separator: ", ")
        
        if method.returnType != "Void" {
          if method.isThrowing {
            body.append("    return try super.\(method.name)(\(superArgs))")
          } else {
            body.append("    return super.\(method.name)(\(superArgs))")
          }
        } else {
          if method.isThrowing {
            body.append("    try super.\(method.name)(\(superArgs))")
          } else {
            body.append("    super.\(method.name)(\(superArgs))")
          }
        }
      }
    }
    
    return """
    \(signature) {
    \(body.joined(separator: "\n"))
      }
    """
  }
  
  // Generate simulation helper methods
  private static func generateSimulationHelperStrings(method: MethodInfo) -> [String] {
    var helpers: [String] = []
    let capitalizedName = method.name.prefix(1).uppercased() + method.name.dropFirst()
    
    if let completion = method.completionParam {
      // Completion-based helpers
      if completion.type.contains("Result<") {
        let successType = extractResultSuccessType(from: completion.type)
        let errorType = extractResultErrorType(from: completion.type)
        
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)(with result: Result<\(successType), \(errorType)>, at index: Int = 0) {")
        helpers.append("    \(method.name)ReceivedResults.append(result)")
        helpers.append("    \(method.name)Completions[index](result)")
        helpers.append("  }")
        
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)WithSuccess(_ value: \(successType), at index: Int = 0) {")
        helpers.append("    let result = Result<\(successType), \(errorType)>.success(value)")
        helpers.append("    \(method.name)ReceivedResults.append(result)")
        helpers.append("    \(method.name)Completions[index](result)")
        helpers.append("  }")
        
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)WithError(_ error: \(errorType), at index: Int = 0) {")
        helpers.append("    let result = Result<\(successType), \(errorType)>.failure(error)")
        helpers.append("    \(method.name)ReceivedResults.append(result)")
        helpers.append("    \(method.name)Completions[index](result)")
        helpers.append("  }")
      }
    } else if method.isAsync {
      // Async helpers
      if method.isThrowing {
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)(with result: Result<\(method.returnType), Error>, at index: Int = 0) {")
        helpers.append("    switch result {")
        helpers.append("    case .success(let value):")
        helpers.append("      \(method.name)Continuations[index].resume(returning: value)")
        helpers.append("    case .failure(let error):")
        helpers.append("      \(method.name)Continuations[index].resume(throwing: error)")
        helpers.append("    }")
        helpers.append("  }")
        
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)WithSuccess(_ value: \(method.returnType), at index: Int = 0) {")
        helpers.append("    \(method.name)Continuations[index].resume(returning: value)")
        helpers.append("  }")
        
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)WithError(_ error: Error, at index: Int = 0) {")
        helpers.append("    \(method.name)Continuations[index].resume(throwing: error)")
        helpers.append("  }")
      } else {
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)(with value: \(method.returnType), at index: Int = 0) {")
        helpers.append("    \(method.name)Continuations[index].resume(returning: value)")
        helpers.append("  }")
      }
    } else if method.returnType.contains("AnyPublisher") {
      // Publisher helpers
      let (outputType, failureType) = extractPublisherTypes(from: method.returnType)
      
      helpers.append("")
      helpers.append("  func send\(capitalizedName)(_ value: \(outputType), at index: Int = 0) {")
      helpers.append("    \(method.name)Subjects[index].send(value)")
      helpers.append("  }")
      
      if failureType != "Never" {
        helpers.append("")
        helpers.append("  func complete\(capitalizedName)WithError(_ error: \(failureType), at index: Int = 0) {")
        helpers.append("    \(method.name)Subjects[index].send(completion: .failure(error))")
        helpers.append("  }")
      }
      
      helpers.append("")
      helpers.append("  func complete\(capitalizedName)(at index: Int = 0) {")
      helpers.append("    \(method.name)Subjects[index].send(completion: .finished)")
      helpers.append("  }")
    }
    
    return helpers
  }
  
  // Generate State enum
  private static func generateStateEnum(methods: [MethodInfo]) -> DeclSyntax {
    var enumCases: [String] = []
    
    for method in methods {
      let capitalizedName = method.name.prefix(1).uppercased() + method.name.dropFirst()
      
      if method.parameters.isEmpty {
        enumCases.append("case \(method.name)")
      } else {
        let params = method.parameters.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        enumCases.append("case \(method.name)(\(params))")
      }
    }
    
    let casesString = enumCases.joined(separator: "\n    ")
    
    return """
    enum State: Equatable {
      \(raw: casesString)
      
      static func == (lhs: State, rhs: State) -> Bool {
        switch (lhs, rhs) {
          \(raw: generateEqualityCases(methods: methods))
        }
      }
    }
    """
  }
  
  // Generate equality cases for State enum
  private static func generateEqualityCases(methods: [MethodInfo]) -> String {
    var cases: [String] = []
    
    for method in methods {
      if method.parameters.isEmpty {
        cases.append("case (.\(method.name), .\(method.name)): return true")
      } else {
        let lhsParams = method.parameters.map { "let lhs\($0.name.capitalized)" }.joined(separator: ", ")
        let rhsParams = method.parameters.map { "let rhs\($0.name.capitalized)" }.joined(separator: ", ")
        let comparisons = method.parameters.map { "lhs\($0.name.capitalized) == rhs\($0.name.capitalized)" }.joined(separator: " && ")
        
        cases.append("case (.\(method.name)(\(lhsParams)), .\(method.name)(\(rhsParams))): return \(comparisons)")
      }
    }
    
    cases.append("default: return false")
    
    return cases.joined(separator: "\n          ")
  }
  
  // Generate method implementations
  private static func generateMethodImplementations(method: MethodInfo) -> [DeclSyntax] {
    var declarations: [DeclSyntax] = []
    let capitalizedName = method.name.prefix(1).uppercased() + method.name.dropFirst()
    
    // Determine method type
    if method.completionParam != nil {
      // Completion-based method
      declarations.append(contentsOf: generateCompletionMethod(method: method, capitalizedName: capitalizedName))
    } else if method.isAsync {
      // Async/await method
      declarations.append(contentsOf: generateAsyncMethod(method: method, capitalizedName: capitalizedName))
    } else if method.returnType.contains("AnyPublisher") {
      // Combine publisher method
      declarations.append(contentsOf: generatePublisherMethod(method: method, capitalizedName: capitalizedName))
    }
    
    return declarations
  }
  
  // Generate completion-based method
  private static func generateCompletionMethod(method: MethodInfo, capitalizedName: String) -> [DeclSyntax] {
    var declarations: [DeclSyntax] = []
    
    guard let completion = method.completionParam else { return [] }
    
    // Storage for completions (remove @escaping for array type)
    let completionType = completion.type.replacingOccurrences(of: "@escaping ", with: "")
    let storageDecl: DeclSyntax = "private var \(raw: method.name)Completions: [\(raw: completionType)] = []"
    declarations.append(storageDecl)
    
    // Simulation helpers - extract Result types if present
    if completion.type.contains("Result<") {
      // Extract success and error types from Result<Success, Failure>
      let successType = extractResultSuccessType(from: completion.type)
      let errorType = extractResultErrorType(from: completion.type)
      
      // complete method with result
      let completeMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)(with result: Result<\(raw: successType), \(raw: errorType)>, at index: Int = 0) {
        \(raw: method.name)Completions[index](result)
      }
      """
      declarations.append(completeMethod)
      
      // complete with success
      let successMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)WithSuccess(_ value: \(raw: successType), at index: Int = 0) {
        \(raw: method.name)Completions[index](.success(value))
      }
      """
      declarations.append(successMethod)
      
      // complete with error
      let errorMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)WithError(_ error: \(raw: errorType), at index: Int = 0) {
        \(raw: method.name)Completions[index](.failure(error))
      }
      """
      declarations.append(errorMethod)
    }
    
    return declarations
  }
  
  // Generate async method
  private static func generateAsyncMethod(method: MethodInfo, capitalizedName: String) -> [DeclSyntax] {
    var declarations: [DeclSyntax] = []
    
    let returnTypeStr = method.returnType
    
    // Storage for continuations
    if method.isThrowing {
      let storageDecl: DeclSyntax = "private var \(raw: method.name)Continuations: [CheckedContinuation<\(raw: returnTypeStr), Error>] = []"
      declarations.append(storageDecl)
      
      // Simulation helper
      let completeMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)(with result: Result<\(raw: returnTypeStr), Error>, at index: Int = 0) {
        switch result {
        case .success(let value):
          \(raw: method.name)Continuations[index].resume(returning: value)
        case .failure(let error):
          \(raw: method.name)Continuations[index].resume(throwing: error)
        }
      }
      """
      declarations.append(completeMethod)
      
      // Success helper
      let successMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)WithSuccess(_ value: \(raw: returnTypeStr), at index: Int = 0) {
        \(raw: method.name)Continuations[index].resume(returning: value)
      }
      """
      declarations.append(successMethod)
      
      // Error helper
      let errorMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)WithError(_ error: Error, at index: Int = 0) {
        \(raw: method.name)Continuations[index].resume(throwing: error)
      }
      """
      declarations.append(errorMethod)
    } else {
      let storageDecl: DeclSyntax = "private var \(raw: method.name)Continuations: [UnsafeContinuation<\(raw: returnTypeStr), Never>] = []"
      declarations.append(storageDecl)
      
      // Simulation helper
      let completeMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)(with value: \(raw: returnTypeStr), at index: Int = 0) {
        \(raw: method.name)Continuations[index].resume(returning: value)
      }
      """
      declarations.append(completeMethod)
    }
    
    return declarations
  }
  
  // Generate publisher method
  private static func generatePublisherMethod(method: MethodInfo, capitalizedName: String) -> [DeclSyntax] {
    var declarations: [DeclSyntax] = []
    
    // Extract Output and Failure types from AnyPublisher<Output, Failure>
    let (outputType, failureType) = extractPublisherTypes(from: method.returnType)
    
    // Storage for subjects
    let storageDecl: DeclSyntax = "private var \(raw: method.name)Subjects: [PassthroughSubject<\(raw: outputType), \(raw: failureType)>] = []"
    declarations.append(storageDecl)
    
    // Call count helper
    let callCountDecl: DeclSyntax = "var \(raw: method.name)CallCount: Int { \(raw: method.name)Subjects.count }"
    declarations.append(callCountDecl)
    
    // Send value helper
    if failureType == "Never" {
      let sendMethod: DeclSyntax = """
      func send\(raw: capitalizedName)(_ value: \(raw: outputType), at index: Int = 0) {
        \(raw: method.name)Subjects[index].send(value)
      }
      """
      declarations.append(sendMethod)
      
      let completeMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)(at index: Int = 0) {
        \(raw: method.name)Subjects[index].send(completion: .finished)
      }
      """
      declarations.append(completeMethod)
    } else {
      let sendMethod: DeclSyntax = """
      func send\(raw: capitalizedName)(_ value: \(raw: outputType), at index: Int = 0) {
        \(raw: method.name)Subjects[index].send(value)
      }
      """
      declarations.append(sendMethod)
      
      let errorMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)WithError(_ error: \(raw: failureType), at index: Int = 0) {
        \(raw: method.name)Subjects[index].send(completion: .failure(error))
      }
      """
      declarations.append(errorMethod)
      
      let finishMethod: DeclSyntax = """
      func complete\(raw: capitalizedName)(at index: Int = 0) {
        \(raw: method.name)Subjects[index].send(completion: .finished)
      }
      """
      declarations.append(finishMethod)
    }
    
    return declarations
  }
  
  // Generate helper methods
  private static func generateHelperMethods() -> [DeclSyntax] {
    return [
      """
      func reset() {
        states.removeAll()
      }
      """,
      """
      func didCall(_ state: State) -> Bool {
        states.contains(state)
      }
      """,
      """
      func callCount(for state: State) -> Int {
        states.filter { $0 == state }.count
      }
      """
    ]
  }
  
  // Helper: Extract Result success type
  private static func extractResultSuccessType(from type: String) -> String {
    // First extract just the Result<...> part from closure types like "@escaping (Result<Data, Error>) -> Void"
    var resultType = type
    if let openParen = type.range(of: "("),
       let closeParen = type.range(of: ")") {
      resultType = String(type[openParen.upperBound..<closeParen.lowerBound])
    }
    
    if let start = resultType.range(of: "Result<") {
      // Find the matching closing > for Result<
      var depth = 0
      var endIndex = start.upperBound
      for char in resultType[start.upperBound...] {
        if char == "<" {
          depth += 1
        } else if char == ">" {
          if depth == 0 {
            break
          }
          depth -= 1
        }
        endIndex = resultType.index(after: endIndex)
      }
      
      let innerTypes = resultType[start.upperBound..<endIndex]
      let components = innerTypes.split(separator: ",", maxSplits: 1)
      if let first = components.first {
        return first.trimmingCharacters(in: .whitespaces)
      }
    }
    return "Any"
  }
  
  // Helper: Extract Result error type
  private static func extractResultErrorType(from type: String) -> String {
    // First extract just the Result<...> part from closure types
    var resultType = type
    if let openParen = type.range(of: "("),
       let closeParen = type.range(of: ")") {
      resultType = String(type[openParen.upperBound..<closeParen.lowerBound])
    }
    
    if let start = resultType.range(of: "Result<") {
      // Find the matching closing > for Result<
      var depth = 0
      var endIndex = start.upperBound
      for char in resultType[start.upperBound...] {
        if char == "<" {
          depth += 1
        } else if char == ">" {
          if depth == 0 {
            break
          }
          depth -= 1
        }
        endIndex = resultType.index(after: endIndex)
      }
      
      let innerTypes = resultType[start.upperBound..<endIndex]
      let components = innerTypes.split(separator: ",", maxSplits: 1)
      if components.count > 1 {
        return components[1].trimmingCharacters(in: .whitespaces)
      }
    }
    return "Error"
  }
  
  // Helper: Extract publisher types
  private static func extractPublisherTypes(from type: String) -> (output: String, failure: String) {
    if let start = type.range(of: "AnyPublisher<"),
       let end = type.range(of: ">", options: .backwards) {
      let innerTypes = type[start.upperBound..<end.lowerBound]
      let components = innerTypes.split(separator: ",", maxSplits: 1)
      let output = components.first?.trimmingCharacters(in: .whitespaces) ?? "Any"
      let failure = components.count > 1 ? components[1].trimmingCharacters(in: .whitespaces) : "Never"
      return (output, failure)
    }
    return ("Any", "Never")
  }
}

// Supporting structures for SpyMacro
struct MethodInfo {
  let name: String
  let parameters: [ParameterInfo]
  let returnType: String
  let isAsync: Bool
  let isThrowing: Bool
  let completionParam: ParameterInfo?
  let isPrivate: Bool
}

struct ParameterInfo {
  let name: String  // Internal name
  let type: String
  let externalName: String?  // External label (nil if '_')
}

struct InitializerInfo {
  let parameters: [ParameterInfo]
  let isThrowing: Bool
}

struct PropertyInfo {
  let name: String
  let type: String
}

struct PublishedPropertyInfo {
  let name: String
  let type: String
}

struct ProtocolPropertyInfo {
  let name: String
  let type: String
  let isReadOnly: Bool
}

@main
struct SharedMacrosPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    StringifyMacro.self,
    SetableMacro.self,
    MockDataMacro.self,
    SpyMacro.self,
  ]
}
