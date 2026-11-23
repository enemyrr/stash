import Foundation
import Testing
@testable import S3Client

/// Vectors from AWS's SigV4 test suite and the S3 "Signature Calculations for the Authorization Header" examples.
struct SigV4Tests {
    let suite = SigV4Signer(
        accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        region: "us-east-1", service: "service"
    )
    let s3 = SigV4Signer(
        accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1"
    )
    let suiteHeaders = ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"]

    @Test func getVanilla() {
        let canonical = suite.canonicalRequest(
            method: "GET", path: "/", query: [:], headers: suiteHeaders, payloadHash: SigV4Signer.emptyPayloadHash
        )
        #expect(canonical.request == """
            GET
            /

            host:example.amazonaws.com
            x-amz-date:20150830T123600Z

            host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        let toSign = suite.stringToSign(canonicalRequest: canonical.request, amzDate: "20150830T123600Z")
        #expect(toSign == """
            AWS4-HMAC-SHA256
            20150830T123600Z
            20150830/us-east-1/service/aws4_request
            bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63
            """)
        #expect(suite.signature(stringToSign: toSign, amzDate: "20150830T123600Z")
            == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func getVanillaAuthorizationHeader() {
        let lowercased = Dictionary(uniqueKeysWithValues: suiteHeaders.map { ($0.key.lowercased(), $0.value) })
        let authorization = suite.authorization(
            method: "GET", path: "/", query: [:], headers: lowercased, payloadHash: SigV4Signer.emptyPayloadHash
        )
        #expect(authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func getVanillaQueryOrderKeyCase() {
        let canonical = suite.canonicalRequest(
            method: "GET", path: "/", query: ["Param2": "value2", "Param1": "value1"],
            headers: suiteHeaders, payloadHash: SigV4Signer.emptyPayloadHash
        )
        #expect(canonical.request.split(separator: "\n", omittingEmptySubsequences: false)[2] == "Param1=value1&Param2=value2")
        let toSign = suite.stringToSign(canonicalRequest: canonical.request, amzDate: "20150830T123600Z")
        #expect(suite.signature(stringToSign: toSign, amzDate: "20150830T123600Z")
            == "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")
    }

    @Test func postVanilla() {
        let canonical = suite.canonicalRequest(
            method: "POST", path: "/", query: [:], headers: suiteHeaders, payloadHash: SigV4Signer.emptyPayloadHash
        )
        let toSign = suite.stringToSign(canonicalRequest: canonical.request, amzDate: "20150830T123600Z")
        #expect(suite.signature(stringToSign: toSign, amzDate: "20150830T123600Z")
            == "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")
    }

    @Test func s3GetObjectWithRange() {
        let canonical = s3.canonicalRequest(
            method: "GET", path: "/test.txt", query: [:],
            headers: [
                "host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9",
                "x-amz-content-sha256": SigV4Signer.emptyPayloadHash, "x-amz-date": "20130524T000000Z",
            ],
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        #expect(canonical.signedHeaders == "host;range;x-amz-content-sha256;x-amz-date")
        let toSign = s3.stringToSign(canonicalRequest: canonical.request, amzDate: "20130524T000000Z")
        #expect(toSign.hasSuffix("\n7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"))
        #expect(s3.signature(stringToSign: toSign, amzDate: "20130524T000000Z")
            == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func s3PutObjectEncodesDollarInKey() {
        let payloadHash = SigV4Signer.sha256Hex(Data("Welcome to Amazon S3.".utf8))
        #expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let canonical = s3.canonicalRequest(
            method: "PUT", path: URIEncoding.encode("/test$file.text", keepSlash: true), query: [:],
            headers: [
                "date": "Fri, 24 May 2013 00:00:00 GMT", "host": "examplebucket.s3.amazonaws.com",
                "x-amz-content-sha256": payloadHash, "x-amz-date": "20130524T000000Z",
                "x-amz-storage-class": "REDUCED_REDUNDANCY",
            ],
            payloadHash: payloadHash
        )
        #expect(canonical.request.hasPrefix("PUT\n/test%24file.text\n"))
        let toSign = s3.stringToSign(canonicalRequest: canonical.request, amzDate: "20130524T000000Z")
        #expect(s3.signature(stringToSign: toSign, amzDate: "20130524T000000Z")
            == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test(arguments: [
        (["lifecycle": ""], "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"),
        (["max-keys": "2", "prefix": "J"], "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"),
    ])
    func s3BucketQueries(query: [String: String], signature: String) {
        let canonical = s3.canonicalRequest(
            method: "GET", path: "/", query: query,
            headers: [
                "host": "examplebucket.s3.amazonaws.com",
                "x-amz-content-sha256": SigV4Signer.emptyPayloadHash, "x-amz-date": "20130524T000000Z",
            ],
            payloadHash: SigV4Signer.emptyPayloadHash
        )
        let toSign = s3.stringToSign(canonicalRequest: canonical.request, amzDate: "20130524T000000Z")
        #expect(s3.signature(stringToSign: toSign, amzDate: "20130524T000000Z") == signature)
    }

    @Test func amzDateFormat() {
        #expect(SigV4Signer.amzDate(Date(timeIntervalSince1970: 1_440_938_160)) == "20150830T123600Z")
    }
}

struct URIEncodingTests {
    @Test(arguments: [
        ("a b", "a%20b"),
        ("åäö", "%C3%A5%C3%A4%C3%B6"),
        ("ሴ", "%E1%88%B4"),
        ("😀", "%F0%9F%98%80"),
        ("a/b", "a%2Fb"),
        ("AZaz09-._~", "AZaz09-._~"),
        ("+*=&?#%$@:,;!'()[]", "%2B%2A%3D%26%3F%23%25%24%40%3A%2C%3B%21%27%28%29%5B%5D"),
        ("", ""),
    ])
    func encodesQueryComponents(input: String, expected: String) {
        #expect(URIEncoding.encode(input) == expected)
    }

    @Test func keepsSlashesInKeys() {
        #expect(URIEncoding.encode("dir with space/sub/ö+1.txt", keepSlash: true) == "dir%20with%20space/sub/%C3%B6%2B1.txt")
    }

    @Test func preservesUnicodeNormalizationForm() {
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(URIEncoding.encode(precomposed) == "%C3%A9")
        #expect(URIEncoding.encode(decomposed) == "e%CC%81")
    }

    @Test(arguments: [
        (S3Config.AddressingStyle.path, "https://s3.example.com/my-bucket/dir%20a/%C3%A5%2Bb.txt?partNumber=1&uploadId=x%2Fy"),
        (.virtualHost, "https://my-bucket.s3.example.com/dir%20a/%C3%A5%2Bb.txt?partNumber=1&uploadId=x%2Fy"),
    ])
    func buildsRequestURLs(style: S3Config.AddressingStyle, expected: String) throws {
        let client = S3Client(config: S3Config(
            endpoint: URL(string: "https://s3.example.com")!, region: "us-east-1", bucket: "my-bucket",
            accessKeyId: "id", secretAccessKey: "secret", addressingStyle: style
        ))
        let request = try client.urlRequest(
            for: S3Request(method: "PUT", key: "dir a/å+b.txt", query: ["uploadId": "x/y", "partNumber": "1"]), date: Date()
        )
        #expect(request.url?.absoluteString == expected)
        #expect(request.value(forHTTPHeaderField: "authorization")?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date") == true)
    }

    @Test func configDescriptionRedactsSecret() {
        let config = S3Config(
            endpoint: URL(string: "https://s3.example.com")!, region: "r", bucket: "b",
            accessKeyId: "id", secretAccessKey: "top-secret"
        )
        #expect(!"\(config)".contains("top-secret"))
        #expect(!String(reflecting: config).contains("top-secret"))
    }
}
