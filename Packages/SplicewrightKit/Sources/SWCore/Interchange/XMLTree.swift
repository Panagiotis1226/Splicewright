import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small XML element tree for reading and writing interchange files (FCP7 XML, FCPXML).
public final class XMLNode {
    public let name: String
    public var attributes: [String: String]
    public var children: [XMLNode]
    public var text: String

    public init(_ name: String, _ attributes: [String: String] = [:], text: String = "", children: [XMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    /// The first child named `name`.
    public func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    public func children(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// Follows a path of child names: `node["media", "video", "format"]`.
    public subscript(_ path: String...) -> XMLNode? {
        var node: XMLNode? = self
        for name in path { node = node?.child(name) }
        return node
    }

    /// The trimmed text of the child at `path`.
    public func value(_ path: String...) -> String? {
        var node: XMLNode? = self
        for name in path { node = node?.child(name) }
        let trimmed = node?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Every descendant named `name`, depth first.
    public func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }

    @discardableResult
    public func add(_ node: XMLNode) -> XMLNode {
        children.append(node)
        return node
    }

    @discardableResult
    public func add(_ name: String, _ text: String) -> XMLNode {
        add(XMLNode(name, text: text))
    }

    // MARK: - Parsing

    public enum ParseError: Error, Equatable {
        case invalid(String)
    }

    public static func parse(_ data: Data) throws -> XMLNode {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw ParseError.invalid(parser.parserError?.localizedDescription ?? "Not an XML file")
        }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLNode(elementName, attributeDict)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }

    // MARK: - Writing

    /// The document with an XML declaration and, if given, a DOCTYPE line.
    public func document(doctype: String? = nil) -> String {
        var lines = [#"<?xml version="1.0" encoding="UTF-8"?>"#]
        if let doctype { lines.append(doctype) }
        lines.append(render(indent: 0))
        return lines.joined(separator: "\n") + "\n"
    }

    private func render(indent: Int) -> String {
        let pad = String(repeating: "    ", count: indent)
        let attributeText = attributes.keys.sorted().map { " \($0)=\"\(Self.escape(attributes[$0] ?? ""))\"" }.joined()
        if children.isEmpty {
            guard !text.isEmpty else { return "\(pad)<\(name)\(attributeText)/>" }
            return "\(pad)<\(name)\(attributeText)>\(Self.escape(text))</\(name)>"
        }
        let inner = children.map { $0.render(indent: indent + 1) }.joined(separator: "\n")
        return "\(pad)<\(name)\(attributeText)>\n\(inner)\n\(pad)</\(name)>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
