import Foundation
import Testing
@testable import LegadoCore

struct SourceNetworkPolicyTests {
    @Test func persistentCookieDomainGroupsSubdomains() {
        #expect(LegadoCookieStore.persistenceDomain(for: "www.example.com") == "example.com")
        #expect(LegadoCookieStore.persistenceDomain(for: "www.content.example.com") == "example.com")
        #expect(LegadoCookieStore.persistenceDomain(for: "www.biquge.com.cn") == "biquge.com.cn")
        #expect(LegadoCookieStore.persistenceDomain(for: "1.2.3.4") == "1.2.3.4")
        #expect(LegadoCookieStore.persistenceDomain(for: "localhost") == "localhost")
    }

    @Test func parsesConcurrentRateFormats() {
        let burst = SourceRateLimit(rawValue: "3/1000")
        let serial = SourceRateLimit(rawValue: "250")
        #expect(burst?.accessLimit == 3)
        #expect(burst?.intervalMilliseconds == 1_000)
        #expect(serial?.accessLimit == 1)
        #expect(serial?.intervalMilliseconds == 250)
        #expect(SourceRateLimit(rawValue: "0") == nil)
        #expect(SourceRateLimit(rawValue: "broken") == nil)
    }

    @Test func fixedWindowReservesAndReportsWait() {
        let limit = SourceRateLimit(rawValue: "2/100")!
        var window = SourceRateWindow()

        #expect(window.reserve(now: 1_000, limit: limit) == 0)
        #expect(window.reserve(now: 1_010, limit: limit) == 0)
        #expect(window.reserve(now: 1_020, limit: limit) == 80)
        #expect(window.reserve(now: 1_100, limit: limit) == 0)
    }

    @Test func cookiesAreIsolatedBySourceAndExplicitValuesWin() async throws {
        let policy = SourceNetworkPolicy()
        let url = URL(string: "https://same.example/path")!
        await policy.setCookieHeader("token=A; shared=stored", sourceID: "source-a", url: url)
        await policy.setCookieHeader("token=B", sourceID: "source-b", url: url)

        #expect(await policy.cookieHeader(sourceID: "source-a", url: url).contains("token=A"))
        #expect(await policy.cookieHeader(sourceID: "source-b", url: url) == "token=B")

        var source = BookSource(bookSourceUrl: "source-a", bookSourceName: "A")
        source.enabledCookieJar = true
        let prepared = try LegadoURLBuilder().prepare(#"https://same.example/path, {"headers":{"Cookie":"shared=explicit"}}"#)
        let transport = RecordingPolicyTransport(results: [.success(.init(data: Data(), statusCode: 200, headers: [:], finalURL: url))])
        _ = try await policy.execute(prepared, source: source, transport: transport, timeout: 1)
        let cookie = await transport.requests().first?.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(cookie.contains("token=A"))
        #expect(cookie.contains("shared=explicit"))
        #expect(!cookie.contains("shared=stored"))
    }

    @MainActor @Test func webViewRefreshKeepsCookiesWithinTheirOriginalPathsAndDomains() async throws {
        let url = URL(string: "https://directory-cookie.example/book/42734/index.html")!
        let host = try #require(url.host)
        let source = BookSource(bookSourceUrl: url.absoluteString, bookSourceName: "目录")
        let policy = SourceNetworkPolicy()
        func cookie(_ name: String, path: String, domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.name: name, .value: "ok", .path: path, .domain: domain]))
        }
        let book = try cookie("book", path: "/book", domain: host)
        let account = try cookie("account", path: "/account", domain: host)
        let external = try cookie("external", path: "/", domain: "unrelated.example")
        defer {
            HTTPCookieStorage.shared.deleteCookie(book)
            HTTPCookieStorage.shared.deleteCookie(account)
        }
        var response = HTTPResponse(data: Data(), statusCode: 200, headers: [:], finalURL: url)
        response.webViewCookies = [book, account, external]
        let browser = RecordingWebViewExecutor(response: response)
        let transport = RecordingPolicyTransport(results: [])
        var request = try LegadoURLBuilder().prepare(url.absoluteString)
        request.useWebView = true
        for _ in 0..<2 {
            _ = try await policy.execute(request, source: source, transport: transport, timeout: 2, webViewExecutor: browser)
        }
        #expect(browser.lastPrepared?.headers["Cookie"] == "book=ok")
        #expect(browser.lastPrepared?.webViewCookies.map(\.path) == ["/book"])
        #expect(await policy.cookieHeader(sourceID: source.id, url: URL(string: "https://\(host)/account/me")!) == "account=ok")
        #expect(await policy.cookieHeader(sourceID: source.id, url: URL(string: "https://\(host)/bookmarks")!).isEmpty)
        #expect(await policy.cookieHeader(sourceID: source.id, url: URL(string: "https://unrelated.example/")!).isEmpty)
    }

    @Test func retriesFailedHTTPResponsesConfiguredNumberAndHonorsDisabledCookieJar() async throws {
        let policy = SourceNetworkPolicy()
        let url = URL(string: "https://retry.example/data")!
        await policy.setCookieHeader("session=secret", sourceID: "source", url: url)
        var source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        source.enabledCookieJar = false
        let prepared = try LegadoURLBuilder().prepare(#"https://retry.example/data, {"retry":2}"#)
        let response = HTTPResponse(data: Data("ok".utf8), statusCode: 200, headers: [:], finalURL: url)
        let failed500 = HTTPResponse(data: Data(), statusCode: 500, headers: [:], finalURL: url)
        let failed502 = HTTPResponse(data: Data(), statusCode: 502, headers: [:], finalURL: url)
        let transport = RecordingPolicyTransport(results: [
            .failure(HTTPClientError.statusResponse(failed500)),
            .failure(HTTPClientError.statusResponse(failed502)),
            .success(response)
        ])

        let result = try await policy.execute(prepared, source: source, transport: transport, timeout: 1)

        #expect(String(decoding: result.data, as: UTF8.self) == "ok")
        #expect(await transport.requests().count == 3)
        #expect(await transport.requests().allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    @Test func doesNotRetryTransportFailures() async throws {
        let prepared = try LegadoURLBuilder().prepare(#"https://retry.example/data, {"retry":3}"#)
        let transport = RecordingPolicyTransport(results: [.failure(URLError(.timedOut))])

        await #expect(throws: URLError.self) {
            _ = try await SourceNetworkPolicy().execute(
                prepared,
                source: .init(bookSourceUrl: "retry", bookSourceName: "重试源"),
                transport: transport,
                timeout: 1
            )
        }

        #expect(await transport.requests().count == 1)
    }

    @Test func capturesCookiesWhileRetryingFailedHTTPResponse() async throws {
        let policy = SourceNetworkPolicy()
        let url = URL(string: "https://auth.example/data")!
        let failed = HTTPResponse(
            data: Data(),
            statusCode: 429,
            headers: ["Set-Cookie": "session=renewed; Path=/; Secure"],
            finalURL: url
        )
        let success = HTTPResponse(data: Data("ok".utf8), statusCode: 200, headers: [:], finalURL: url)
        let transport = RecordingPolicyTransport(results: [
            .failure(HTTPClientError.statusResponse(failed)),
            .success(success)
        ])
        let source = BookSource(bookSourceUrl: "auth-source", bookSourceName: "登录源")
        let prepared = try LegadoURLBuilder().prepare(#"https://auth.example/data, {"retry":1}"#)

        _ = try await policy.execute(prepared, source: source, transport: transport, timeout: 1)

        #expect(await policy.cookieHeader(sourceID: source.id, url: url).contains("session=renewed"))
        #expect(await transport.requests().count == 2)
    }

    @Test func decodesExplicitLegacyCharsetAndHeaderCharset() throws {
        let gb18030 = try #require(HTTPTextDecoder.encoding(named: "GB18030"))
        let chinese = "旧编码正文"
        let legacyData = try #require(chinese.data(using: gb18030))
        let url = try #require(URL(string: "https://encoding.example"))

        let explicit = HTTPResponse(data: legacyData, statusCode: 200, headers: [:], finalURL: url, requestedCharset: "gbk")
        let header = HTTPResponse(data: legacyData, statusCode: 200, headers: ["Content-Type": "text/html; charset=GB18030"], finalURL: url)

        #expect(explicit.decodedText == chinese)
        #expect(header.decodedText == chinese)
    }

    @Test func removesUnicodeBOMBeforeDecoding() throws {
        let url = try #require(URL(string: "https://encoding.example"))
        let text = "目录正文"
        var data = Data([0xFF, 0xFE])
        data.append(try #require(text.data(using: .utf16LittleEndian)))

        #expect(HTTPResponse(data: data, statusCode: 200, headers: [:], finalURL: url).decodedText == text)
    }

    @Test func appliesResponseBodyJavaScriptAndCarriesVariables() async throws {
        let url = try #require(URL(string: "https://script.example/content"))
        let prepared = try LegadoURLBuilder().prepare(
            #"https://script.example/content, {"bodyJs":"java.put('bodyChanged', 'yes'); result.replace('旧正文', '新正文')"}"#
        )
        let transport = RecordingPolicyTransport(results: [.success(.init(
            data: Data("旧正文".utf8),
            statusCode: 200,
            headers: [:],
            finalURL: url
        ))])

        let response = try await SourceNetworkPolicy().execute(
            prepared,
            source: .init(bookSourceUrl: "script", bookSourceName: "脚本源"),
            transport: transport,
            timeout: 1
        )

        #expect(response.decodedText == "新正文")
        #expect(response.requestVariables["bodyChanged"] == "yes")
    }

    @Test(arguments: [false, true]) func webScriptAloneDoesNotEnableWebViewAndBodyScriptStillRuns(explicitlyDisabled: Bool) async throws {
        let url = try #require(URL(string: "https://plain-http.test/content"))
        let options = explicitlyDisabled ? #"{"webView":false,"webJs":"throw new Error('must not run')","bodyJs":"result + '-body'"}"#
            : #"{"webJs":"throw new Error('must not run')","bodyJs":"result + '-body'"}"#
        let prepared = try LegadoURLBuilder().prepare(url.absoluteString + "," + options)
        let transport = RecordingPolicyTransport(results: [.success(.init(data: Data("HTTP".utf8), statusCode: 200, headers: [:], finalURL: url))])
        let executor = await RecordingWebViewExecutor(response: .init(data: Data("wrong".utf8), statusCode: 200, headers: [:], finalURL: url))
        let result = try await SourceNetworkPolicy().execute(prepared, source: .init(bookSourceUrl: "source", bookSourceName: "源"),
            transport: transport, timeout: 1, webViewExecutor: executor)
        #expect(result.decodedText == "HTTP-body")
        #expect(await transport.requests().count == 1)
        #expect(await executor.callCount == 0)
    }

    @Test func inactiveWebScriptDoesNotBlockDataURIOrStreamingHTTP() async throws {
        let source = BookSource(bookSourceUrl: "source", bookSourceName: "源")
        let data = try LegadoURLBuilder().prepare(#"data:text/plain,fixture,{"webJs":"throw new Error('ignored')","bodyJs":"result + '-body'"}"#)
        let policy = SourceNetworkPolicy()
        let result = try await policy.execute(data, source: source, transport: RecordingPolicyTransport(results: []), timeout: 1)
        #expect(result.decodedText == "fixture-body")
        let url = try #require(URL(string: "https://plain-http.test/stream"))
        let stream = try LegadoURLBuilder().prepare(url.absoluteString + #",{"webJs":"throw new Error('ignored')"}"#)
        let transport = RecordingStreamingTransport(url: url, chunks: [Data("a".utf8), Data("b".utf8)])
        let streamed = try await policy.executeStream(stream, source: source, transport: transport, timeout: 1)
        var received = Data()
        for try await chunk in streamed.chunks { received.append(chunk) }
        #expect(received == Data("ab".utf8))
    }

    @Test func routesWebViewRequestsThroughExecutorAndStillAppliesBodyJS() async throws {
        let url = try #require(URL(string: "https://web.example/rendered"))
        let prepared = try LegadoURLBuilder().prepare(
            #"https://web.example/page, {"webView":true,"webJs":"document.body.dataset.ready='1'","webViewDelayTime":250,"bodyJs":"result.replace('原始', '渲染')"}"#
        )
        let executor = await MainActor.run { RecordingWebViewExecutor(response: .init(
            data: Data("<html>原始正文</html>".utf8),
            statusCode: 200,
            headers: [:],
            finalURL: url
        )) }

        let response = try await SourceNetworkPolicy().execute(
            prepared,
            source: .init(bookSourceUrl: "web", bookSourceName: "网页源"),
            transport: RecordingPolicyTransport(results: []),
            timeout: 2,
            webViewExecutor: executor
        )

        #expect(response.decodedText == "<html>渲染正文</html>")
        #expect(await executor.callCount == 1)
        #expect(await executor.lastPrepared?.webJavaScript?.contains("dataset.ready") == true)
        #expect(await executor.lastPrepared?.webViewDelayMilliseconds == 250)
    }

    @Test func recordsRealPreparedRequestAndFinalResponseForDifferentialTesting() async throws {
        let url = try #require(URL(string: "https://snapshot.example/final"))
        let prepared = try LegadoURLBuilder().prepare(
            #"https://snapshot.example/search?q={{key}}, {"headers":{"Cookie":"session=secret","X-Test":"yes"},"retry":2}"#,
            context: .init(key: "测试")
        )
        let response = HTTPResponse(
            data: Data("正文".utf8),
            statusCode: 200,
            headers: ["Content-Type": "text/plain; charset=utf-8", "Set-Cookie": "token=private; Path=/"],
            finalURL: url
        )
        let recorder = MemoryDifferentialSnapshotRecorder(caseID: "html-001")

        _ = try await SourceNetworkPolicy().execute(
            prepared,
            source: .init(bookSourceUrl: "snapshot-source", bookSourceName: "快照源"),
            transport: RecordingPolicyTransport(results: [.success(response)]),
            timeout: 12,
            snapshotRecorder: recorder,
            snapshotStage: .search
        )

        let snapshots = await recorder.snapshots
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.caseID == "html-001")
        #expect(snapshot.stage == .search)
        #expect(snapshot.request.ruleURL.contains("{{key}}"))
        #expect(snapshot.request.renderedURL.contains("%E6%B5%8B%E8%AF%95"))
        #expect(snapshot.request.headers["x-test"] == "yes")
        #expect(snapshot.request.headers["cookie"]?.contains("secret") == false)
        #expect(snapshot.response.finalURL == url.absoluteString)
        #expect(snapshot.response.bodySHA256.count == 64)
        #expect(snapshot.response.setCookies["token"]?.contains("private") == false)
    }

    @Test func emitsBusinessSnapshotFromContentReport() throws {
        let report = ChapterContentReport(
            title: "第一章",
            content: "正文",
            supplementalContent: "副正文",
            diagnostics: [],
            pagesVisited: 2
        )
        let snapshot = DifferentialBusinessSnapshot.content(caseID: "json-001", report: report)
        let object = try JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let content = result?["content"] as? [String: Any]

        #expect(object?["platform"] as? String == "ios")
        #expect(object?["flow"] as? String == "content")
        #expect(content?["text"] as? String == "正文")
        #expect(content?["pagesVisited"] as? Int == 2)
    }

    @Test func typeOptionReturnsLowercaseHex() async throws {
        let url = try #require(URL(string: "https://binary.example/image"))
        let prepared = try LegadoURLBuilder().prepare(#"https://binary.example/image, {"type":"image"}"#)
        let transport = RecordingPolicyTransport(results: [.success(.init(
            data: Data([0x00, 0x7F, 0xA5, 0xFF]), statusCode: 200, headers: [:], finalURL: url
        ))])

        let response = try await SourceNetworkPolicy().execute(
            prepared,
            source: .init(bookSourceUrl: "binary", bookSourceName: "二进制源"),
            transport: transport,
            timeout: 1
        )

        #expect(response.decodedText == "007fa5ff")
    }

    @Test func readsBase64DataURIWithoutCallingNetworkTransport() async throws {
        let prepared = try LegadoURLBuilder().prepare(
            #"data:application/octet-stream;base64,AP+l, {"type":"image"}"#
        )
        let transport = RecordingPolicyTransport(results: [])

        let response = try await SourceNetworkPolicy().execute(
            prepared,
            source: .init(bookSourceUrl: "data-uri", bookSourceName: "内嵌数据源"),
            transport: transport,
            timeout: 1
        )

        #expect(response.decodedText == "00ffa5")
        #expect(response.headers["Content-Type"] == "application/octet-stream")
        #expect(await transport.requests().isEmpty)
    }

    @Test func sourceProxyHeaderIsRemovedAndRoutedThroughProxyTransport() async throws {
        let url = try #require(URL(string: "https://proxy.example/data"))
        let prepared = try LegadoURLBuilder().prepare(
            "https://proxy.example/data",
            defaultHeaders: ["proxy": "socks5://127.0.0.1:1080"]
        )
        let transport = ProxyRecordingPolicyTransport(response: .init(
            data: Data("ok".utf8), statusCode: 200, headers: [:], finalURL: url
        ))

        _ = try await SourceNetworkPolicy().execute(
            prepared,
            source: .init(bookSourceUrl: "proxy", bookSourceName: "代理源"),
            transport: transport,
            timeout: 1
        )

        #expect(await transport.proxy == "socks5://127.0.0.1:1080")
        #expect(await transport.request?.value(forHTTPHeaderField: "proxy") == nil)
    }

    @Test func recordsFinalHTTPFailureAndErrorBodyForDifferentialTesting() async throws {
        let url = try #require(URL(string: "https://failure.example/data"))
        let failed = HTTPResponse(
            data: Data("temporary unavailable".utf8),
            statusCode: 503,
            headers: ["Retry-After": "0"],
            finalURL: url
        )
        let recorder = MemoryDifferentialSnapshotRecorder(caseID: "html-002")
        let prepared = try LegadoURLBuilder().prepare("https://failure.example/data")

        await #expect(throws: HTTPClientError.self) {
            _ = try await SourceNetworkPolicy().execute(
                prepared,
                source: .init(bookSourceUrl: "failure", bookSourceName: "失败源"),
                transport: RecordingPolicyTransport(results: [.failure(HTTPClientError.statusResponse(failed))]),
                timeout: 1,
                snapshotRecorder: recorder,
                snapshotStage: .detail
            )
        }

        let snapshots = await recorder.snapshots
        let snapshot = try #require(snapshots.first)
        #expect(snapshot.response.statusCode == 503)
        #expect(snapshot.response.bodySHA256.count == 64)
        #expect(snapshot.response.error?.code == "http.503")
        #expect(snapshot.response.error?.legadoCode == -7)
    }

    @Test func httpTTSRendersSpeakVariablesAndReturnsBinaryAudio() async throws {
        let url = try #require(URL(string: "https://tts.example/audio"))
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let transport = RecordingPolicyTransport(results: [.success(.init(
            data: audio,
            statusCode: 200,
            headers: ["Content-Type": "audio/wav; charset=binary"],
            finalURL: url
        ))])
        var engine = HttpTTS(id: 9, name: "测试", url: #"https://tts.example/audio, {"method":"POST","body":"text={{speakText}}&speed={{speakSpeed}}"}"#)
        engine.contentType = #"audio/.*"#
        engine.header = #"{"X-Engine":"legado"}"#
        engine.loginCheckJs = #"if (result.headers().get('Content-Type').indexOf('audio/') !== 0) throw 'bad content'; result"#
        let cache = HttpTTSAudioCache(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))

        let service = HttpTTSService(
            networkPolicy: .init(),
            transport: transport,
            cache: cache
        )
        let result = try await service.audio(engine: engine, text: "第一段", speechRate: 7)
        let cached = try await service.audio(engine: engine, text: "第一段", speechRate: 7)

        #expect(result.data == audio)
        #expect(cached.data == audio)
        #expect(result.contentType == "audio/wav")
        let requests = await transport.requests()
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("speed=7"))
        #expect(request.value(forHTTPHeaderField: "X-Engine") == "legado")
        #expect(requests.count == 1)
    }

    @Test func httpTTSBindsSpeechGlobalsForScriptedEngine() async throws {
        let endpoint = try #require(URL(string: "https://tts.example/audio"))
        let transport = RecordingPolicyTransport(results: [.success(.init(
            data: Data([1, 2]), statusCode: 200, headers: ["Content-Type": "audio/mpeg"], finalURL: endpoint
        ))])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HttpTTSService(networkPolicy: .init(), transport: transport, cache: .init(directory: directory))
        var engine = HttpTTS(id: 42, name: "脚本朗读", url: "@js:apiurl(speakText,speakSpeed);")
        engine.jsLib = """
            function apiurl(text, speed) {
                return 'https://tts.example/audio?t=' + encodeURIComponent(text) + '&next=' + (speed + 1);
            }
            """
        engine.loginCheckJs = """
            if (speakText !== java.get('speakText') || speakSpeed !== 15) throw 'missing request values';
            """

        _ = try await service.audioStream(engine: engine, text: "你好 & '世界'", speechRate: 15)
        let request = try #require(await transport.requests().first)
        let query = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        #expect(query == [URLQueryItem(name: "t", value: "你好 & '世界'"), URLQueryItem(name: "next", value: "16")])
    }

    @Test func azureCatalogUsesSavedCredentialsAndRegionalVoices() async throws {
        let saved = #"{"region":"eastasia","key":"test-key","voice":"zh-CN-XiaoxiaoNeural"}"#
        let settings = try JSONDecoder().decode(AzureSpeechSettings.self, from: Data(saved.utf8))
        #expect(settings.voice == "zh-CN-XiaoxiaoNeural")
        let url = try #require(URL(string: "https://eastasia.tts.speech.microsoft.com/cognitiveservices/voices/list"))
        let catalog = #"[{"ShortName":"en-GB-SoniaNeural","LocalName":"Sonia","Locale":"en-GB"},{"ShortName":"zh-TW-YunJheNeural","LocalName":"雲哲","Locale":"zh-TW"}]"#
        let transport = RecordingPolicyTransport(results: [.success(.init(data: Data(catalog.utf8), statusCode: 200, headers: [:], finalURL: url))])
        let voices = try await settings.availableVoices(transport: transport)
        #expect(voices.map(\.name) == ["雲哲", "Sonia"])
        let request = try #require(await transport.requests().first)
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "test-key")
        let markdown = "| 东亚 | `https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1` |\r\n| 测试 | `https://example.com/cognitiveservices/v1` |"
        #expect(try AzureSpeechSettings.regionNames(in: markdown) == ["eastasia": "东亚"])
    }

    @Test func naturalSpeechPresetSendsSelectedVoiceAndKeepsPreviewsSeparate() async throws {
        var settings = AzureSpeechSettings(region: " eastasia ", key: "test-key")
        let endpoint = try #require(URL(string: "https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1"))
        let transport = RecordingPolicyTransport(results: [1, 2].map { byte in
            .success(.init(data: Data([byte]), statusCode: 200, headers: ["Content-Type": "audio/mpeg"], finalURL: endpoint))
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HttpTTSService(networkPolicy: .init(), transport: transport, cache: .init(directory: directory))
        let voices = ["zh-CN-YunjianNeural", "en-US-JennyNeural"]
        for voice in voices {
            settings.voice = voice
            settings.locale = String(voice.prefix(5))
            _ = try await service.audio(engine: settings.engine(), text: "中文 & <雨> {{123}}", speechRate: 15)
        }
        let requests = await transport.requests()
        #expect(requests.count == 2)
        for (request, voice) in zip(requests, voices) {
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "test-key")
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(body.contains(voice))
            #expect(body.contains("xml:lang='\(voice.prefix(5))'"))
            #expect(body.contains("rate='+50%'"))
            #expect(body.contains("中文 &amp; &lt;雨&gt; {{123}}"))
        }
        settings.region = "example.org/path?"
        #expect(throws: RuleEngineError.self) { try settings.engine() }
    }

    @Test func bundledNextTTSRequiresAConfiguredEndpoint() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/httpTTS.json"))
        let engines = try JSONDecoder().decode([HttpTTS].self, from: data)
        var engine = try #require(engines.first { $0.name.contains("Next引擎") })
        engine.id = Int64.random(in: 1...Int64.max)
        engine.concurrentRate = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HttpTTSAudioCache(directory: directory)
        let unconfiguredTransport = RecordingPolicyTransport(results: [])
        let service = HttpTTSService(networkPolicy: .init(), transport: unconfiguredTransport, cache: cache)
        do {
            _ = try await service.audioStream(engine: engine, text: "试音", speechRate: 10)
            Issue.record("缺少接口时应提示配置")
        } catch {
            #expect(error.localizedDescription.contains("登录表单"))
        }
        #expect(await unconfiguredTransport.requests().isEmpty)

        let endpoint = try #require(URL(string: "https://tts.example/tts"))
        let info = #"{"api":"https://tts.example/tts","发言人":"云间","风格":"无风格"}"#
        let store = BookSourceRuntimeStore.shared
        store.put(sourceID: engine.sourceKey, key: "loginInfo", value: info)
        defer { store.put(sourceID: engine.sourceKey, key: "loginInfo", value: "") }
        let transport = RecordingPolicyTransport(results: [.success(.init(
            data: Data([1]), statusCode: 200, headers: ["Content-Type": "audio/mpeg"], finalURL: endpoint
        ))])
        let configured = HttpTTSService(networkPolicy: .init(), transport: transport, cache: cache)
        _ = try await configured.audioStream(engine: engine, text: "试音", speechRate: 10)
        let request = try #require(await transport.requests().first)
        #expect(request.url?.host == endpoint.host)
        #expect(request.url?.query?.contains("v=zh-CN-YunjianNeural") == true)
    }

    @Test func httpTTSStreamsChunksAndStoresCompletedResponseInCache() async throws {
        let url = try #require(URL(string: "https://tts.example/stream"))
        let first = Data(repeating: 0x41, count: 4)
        let second = Data(repeating: 0x42, count: 3)
        let transport = RecordingStreamingTransport(url: url, chunks: [first, second])
        var engine = HttpTTS(id: 12, name: "流式", url: url.absoluteString)
        engine.contentType = #"audio/.*"#
        let cache = HttpTTSAudioCache(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let service = HttpTTSService(networkPolicy: .init(), transport: transport, cache: cache)

        let streamed = try await service.audioStream(engine: engine, text: "第一段", speechRate: 10)
        #expect(streamed.isIncremental)
        #expect(streamed.expectedContentLength == 7)
        var received: [Data] = []
        for try await chunk in streamed.chunks { received.append(chunk) }
        #expect(received == [first, second])

        let cached = try await service.audioStream(engine: engine, text: "第一段", speechRate: 10)
        #expect(!cached.isIncremental)
        var cachedData = Data()
        for try await chunk in cached.chunks { cachedData.append(chunk) }
        #expect(cachedData == first + second)
        #expect(await transport.requestCount() == 1)
    }

    @Test func httpTTSCacheSeparatesEnginesAndInvalidatesEditedVoiceConfiguration() async throws {
        let url = try #require(URL(string: "https://tts.example/shared"))
        let transport = RecordingPolicyTransport(results: ["first", "second", "edited"].map {
            .success(.init(data: Data($0.utf8), statusCode: 200, headers: ["Content-Type": "audio/mpeg"], finalURL: url))
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HttpTTSService(networkPolicy: .init(), transport: transport, cache: .init(directory: directory))
        var engine = HttpTTS(id: 1, name: "声音一", url: url.absoluteString)
        engine.header = #"{"X-Voice":"first"}"#
        let first = try await service.audio(engine: engine, text: "相同正文", speechRate: 5)
        engine.id = 2
        let second = try await service.audio(engine: engine, text: "相同正文", speechRate: 5)
        engine.header = #"{"X-Voice":"edited"}"#
        let edited = try await service.audio(engine: engine, text: "相同正文", speechRate: 5)
        let cached = try await service.audio(engine: engine, text: "相同正文", speechRate: 5)
        #expect(first.data == Data("first".utf8))
        #expect(second.data == Data("second".utf8))
        #expect(edited.data == Data("edited".utf8))
        #expect(cached.data == edited.data)
        #expect(await transport.requests().count == 3)
    }

    @Test func httpTTSDecodesDefaultsWithMissingFieldsAndLoginUIArray() throws {
        let data = Data(#"{"id":-100,"name":"百度","url":"https://tts.example","loginUi":[{"name":"token","type":"text"}]}"#.utf8)
        let value = try JSONDecoder().decode(HttpTTS.self, from: data)
        #expect(value.id == -100)
        #expect(value.concurrentRate == nil)
        #expect(value.enabledCookieJar == false)
        #expect(value.loginUi?.contains("token") == true)
        #expect(value.lastUpdateTime > 0)
    }

    @Test func httpTTSRejectsTextErrorResponse() async throws {
        let url = try #require(URL(string: "https://tts.example/error"))
        let response = HTTPResponse(
            data: Data("额度不足".utf8),
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            finalURL: url
        )
        let transport = RecordingPolicyTransport(results: Array(repeating: .success(response), count: 6))
        let engine = HttpTTS(id: 10, name: "错误", url: url.absoluteString)
        let cache = HttpTTSAudioCache(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))

        await #expect(throws: HttpTTSServiceError.self) {
            _ = try await HttpTTSService(
                networkPolicy: .init(),
                transport: transport,
                cache: cache
            ).audio(engine: engine, text: "测试", speechRate: 5)
        }
        #expect(await transport.requests().count == 6)
    }

    @Test func httpTTSRebuildsRequestWhenLoginCheckInitializesURL() async throws {
        let url = try #require(URL(string: "https://tts.example/recover"))
        let transport = RecordingPolicyTransport(results: [
            .success(.init(
                data: Data(#"{"status":40000001}"#.utf8),
                statusCode: 401,
                headers: ["Content-Type": "application/json"],
                finalURL: url
            )),
            .success(.init(
                data: Data([0x49, 0x44, 0x33]),
                statusCode: 200,
                headers: ["Content-Type": "audio/mpeg"],
                finalURL: url
            ))
        ])
        var engine = HttpTTS(id: 11, name: "恢复", url: url.absoluteString)
        engine.loginCheckJs = "java.initUrl(); java.getResponse()"
        engine.contentType = "audio/.*"
        let cache = HttpTTSAudioCache(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))

        let audio = try await HttpTTSService(
            networkPolicy: .init(),
            transport: transport,
            cache: cache
        ).audio(engine: engine, text: "测试", speechRate: 5)

        #expect(audio.contentType == "audio/mpeg")
        #expect(await transport.requests().count == 2)
    }
}

private actor RecordingPolicyTransport: HTTPTransport {
    private var results: [Result<HTTPResponse, any Error>]
    private var recorded: [URLRequest] = []

    init(results: [Result<HTTPResponse, any Error>]) { self.results = results }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        recorded.append(request)
        guard !results.isEmpty else { throw URLError(.badServerResponse) }
        return try results.removeFirst().get()
    }

    func requests() -> [URLRequest] { recorded }
}

private actor RecordingStreamingTransport: StreamingHTTPTransport {
    let url: URL
    let values: [Data]
    private var count = 0

    init(url: URL, chunks: [Data]) {
        self.url = url
        values = chunks
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        count += 1
        return .init(
            data: values.reduce(into: Data()) { $0.append($1) },
            statusCode: 200,
            headers: ["Content-Type": "audio/mpeg"],
            finalURL: url
        )
    }

    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        count += 1
        let chunks = values
        return .init(
            statusCode: 200,
            headers: ["Content-Type": "audio/mpeg"],
            finalURL: url,
            expectedContentLength: Int64(chunks.reduce(0) { $0 + $1.count }),
            chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    func requestCount() -> Int { count }
}

private actor ProxyRecordingPolicyTransport: ProxyHTTPTransport {
    let response: HTTPResponse
    private(set) var proxy: String?
    private(set) var request: URLRequest?

    init(response: HTTPResponse) { self.response = response }

    func data(for request: URLRequest) async throws -> HTTPResponse { response }

    func data(for request: URLRequest, proxy: String) async throws -> HTTPResponse {
        self.request = request
        self.proxy = proxy
        return response
    }
}

@MainActor
private final class RecordingWebViewExecutor: SourceWebViewRequestExecuting, @unchecked Sendable {
    let response: HTTPResponse
    private(set) var callCount = 0
    private(set) var lastPrepared: PreparedRequest?

    init(response: HTTPResponse) { self.response = response }

    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        callCount += 1
        lastPrepared = prepared
        return response
    }
}
