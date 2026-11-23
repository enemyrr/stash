import Foundation

struct XMLNode: Sendable, Equatable {
    var name: String
    var text = ""
    var children: [XMLNode] = []

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text }

    static func parse(_ data: Data) throws -> XMLNode {
        // CopyObject and CompleteMultipartUpload may send keep-alive whitespace before the XML declaration.
        let parser = XMLParser(data: Data(data.drop { [0x20, 0x09, 0x0A, 0x0D].contains($0) }))
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.stack.first?.children.first else {
            throw S3Error.invalidResponse("Malformed XML: \(parser.parserError?.localizedDescription ?? "empty document")")
        }
        return root
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var stack = [XMLNode(name: "")]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        stack.append(XMLNode(name: elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let node = stack.removeLast()
        stack[stack.count - 1].children.append(node)
    }
}
