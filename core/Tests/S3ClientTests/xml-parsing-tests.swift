import Foundation
import Testing
@testable import S3Client

struct XMLParsingTests {
    @Test func parsesURLEncodedListing() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Name>bucket</Name><Prefix>a%2Fb+c%2F</Prefix><KeyCount>2</KeyCount><MaxKeys>1000</MaxKeys>
              <Delimiter>%2F</Delimiter><EncodingType>url</EncodingType>
              <IsTruncated>true</IsTruncated><NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
              <Contents>
                <Key>a/b+c/%C3%A5%2B1.txt</Key><LastModified>2009-10-12T17:50:30.000Z</LastModified>
                <ETag>&quot;fba9dede5f27731c9771645a39863328&quot;</ETag><Size>434234</Size><StorageClass>STANDARD</StorageClass>
              </Contents>
              <Contents>
                <Key>a/b+c/x</Key><LastModified>2009-10-12T17:50:30Z</LastModified><ETag>"e-2"</ETag><Size>0</Size>
              </Contents>
              <CommonPrefixes><Prefix>a/b+c/sub%20dir/</Prefix></CommonPrefixes>
            </ListBucketResult>
            """
        let result = try ListResult(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(result.objects.map(\.key) == ["a/b c/å+1.txt", "a/b c/x"])
        #expect(result.objects[0].etag == "fba9dede5f27731c9771645a39863328")
        #expect(result.objects[0].size == 434_234)
        #expect(result.objects[0].lastModified == Date(timeIntervalSince1970: 1_255_369_830))
        #expect(result.objects[1].lastModified == Date(timeIntervalSince1970: 1_255_369_830))
        #expect(result.commonPrefixes == ["a/b c/sub dir/"])
        #expect(result.nextContinuationToken == "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
    }

    @Test func keepsRawKeysWithoutEncodingType() throws {
        let xml = """
            <ListBucketResult><IsTruncated>false</IsTruncated>
            <Contents><Key> a+b%20 </Key><LastModified>2024-01-01T00:00:00.000Z</LastModified><ETag>"x"</ETag><Size>1</Size></Contents>
            </ListBucketResult>
            """
        let result = try ListResult(xml: XMLNode.parse(Data(xml.utf8)))
        #expect(result.objects.map(\.key) == [" a+b%20 "])
        #expect(result.nextContinuationToken == nil)
    }

    @Test func rejectsMalformedURLEncodedKey() {
        let xml = """
            <ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>
            <Contents><Key>a%2</Key><LastModified>2024-01-01T00:00:00Z</LastModified><ETag>"x"</ETag><Size>1</Size></Contents>
            </ListBucketResult>
            """
        #expect(throws: S3Error.self) { try ListResult(xml: XMLNode.parse(Data(xml.utf8))) }
    }

    @Test func rejectsTruncatedListingWithoutToken() {
        let xml = "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"
        #expect(throws: S3Error.self) { try ListResult(xml: XMLNode.parse(Data(xml.utf8))) }
    }

    @Test func parsesCopyResultAfterKeepAliveWhitespace() throws {
        let xml = "   \n  <?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CopyObjectResult><LastModified>2024-01-01T00:00:00.000Z</LastModified><ETag>\"abc\"</ETag></CopyObjectResult>"
        let root = try XMLNode.parse(Data(xml.utf8))
        #expect(root.name == "CopyObjectResult")
        #expect(root.value("ETag") == "\"abc\"")
    }

    @Test func parsesDeleteFailures() throws {
        let xml = """
            <DeleteResult>
              <Deleted><Key>ok</Key></Deleted>
              <Error><Key>a &amp; b</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
            </DeleteResult>
            """
        #expect(try DeleteFailure.parse(XMLNode.parse(Data(xml.utf8)))
            == [DeleteFailure(key: "a & b", code: "AccessDenied", message: "Access Denied")])
    }

    @Test func rejectsMalformedXML() {
        #expect(throws: S3Error.self) { try XMLNode.parse(Data("<a><b></a>".utf8)) }
        #expect(throws: S3Error.self) { try XMLNode.parse(Data()) }
    }

    @Test func escapesKeysForRequestBodies() throws {
        let key = "a&b<c>\"d'"
        let root = try XMLNode.parse(Data("<Key>\(XMLNode.escape(key))</Key>".utf8))
        #expect(root.text == key)
    }

    @Test func parsesHeadHeaders() {
        let info = ObjectInfo(headers: [
            "content-length": "10", "content-range": "bytes 0-9/4096", "etag": "\"abc-3\"",
            "last-modified": "Wed, 12 Oct 2009 17:50:00 GMT", "content-type": "text/plain",
            "x-amz-meta-mtime": "1700000000.5", "x-amz-request-id": "r",
        ])
        #expect(info == ObjectInfo(
            size: 4096, etag: "abc-3", lastModified: Date(timeIntervalSince1970: 1_255_369_800),
            contentType: "text/plain", metadata: ["mtime": "1700000000.5"]
        ))
    }

    @Test func splitsPartsWithinLimit() {
        let mib: Int64 = 1 << 20
        let parts = S3Client.partRanges(size: 70 * mib, partSize: 16 * mib)
        #expect(parts.count == 5)
        #expect(parts.last == (64 * mib)...(70 * mib - 1))
        #expect(S3Client.partRanges(size: 32, partSize: 16) == [0...15, 16...31])
        #expect(S3Client.partRanges(size: 200_000 << 20, partSize: 16 << 20).count <= 10_000)
    }
}
