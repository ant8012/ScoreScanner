import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A parsed XML element: tag, attributes, text and children, for reading and rewriting MusicXML.
final class XMLNode {
    let tag: String
    var attributes: [String: String]
    var text: String
    var children: [XMLNode]

    init(_ tag: String, text: String = "", attributes: [String: String] = [:], children: [XMLNode] = []) {
        self.tag = tag; self.text = text; self.attributes = attributes; self.children = children
    }
    func first(_ tag: String) -> XMLNode? { children.first { $0.tag == tag } }
    func all(_ tag: String) -> [XMLNode] { children.filter { $0.tag == tag } }
    func integer() throws -> Int {
        guard let value = Int(text) else { throw ScannerError.invalid("Invalid integer in MusicXML \(tag)") }
        return value
    }
    func duration() throws -> Int { try first("duration")?.integer() ?? 0 }
    func copy() -> XMLNode { XMLNode(tag, text: text, attributes: attributes, children: children.map { $0.copy() }) }
    func serialized() -> String {
        let attrs = attributes.keys.sorted().map { " \($0)=\"\(escape(attributes[$0]!))\"" }.joined()
        return "<\(tag)\(attrs)>" + escape(text) + children.map { $0.serialized() }.joined() + "</\(tag)>"
    }
    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func parse(_ data: Data) throws -> XMLNode {
        let parser = XMLParser(data: data)
        let delegate = TreeParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else {
            throw ScannerError.invalid("Invalid MusicXML: \(parser.parserError?.localizedDescription ?? "missing root")")
        }
        return root
    }
}

private final class TreeParser: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = XMLNode(elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let node = stack.popLast() { node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
