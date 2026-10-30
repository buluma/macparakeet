import XCTest
@testable import MacParakeetCore

final class KnowledgeCardRecoveryTests: XCTestCase {
    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        super.tearDown()
    }

    private static let validMeetingJSON = """
        {"synopsis":"Synthetic release review.","topics":[],"decisions":[],"actions":[]}
        """

    func testNativeSchemaTruncationRetriesWithMoreRoomAndAccumulatesUsage() async throws {
        for reason in ["length", "max_tokens", "MAX_TOKENS", "max_output_tokens"] {
            let telemetry = CardTelemetrySpy()
            Telemetry.configure(telemetry)
            let client = MockLLMClient()
            client.responseContents = ["{\"synopsis\":", Self.validMeetingJSON]
            client.responseFinishReasons = [reason, "stop"]
            client.responseUsages = [
                TokenUsage(promptTokens: 50, completionTokens: 2_048),
                TokenUsage(promptTokens: 60, completionTokens: 900),
            ]
            let service = Self.service(client: client, config: .openai(apiKey: "test"))

            let result = try await service.generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)

            XCTAssertEqual(result.output, Self.validMeetingJSON)
            XCTAssertEqual(client.capturedOptionBatches.map(\.maxTokens), [2_048, 4_096])
            XCTAssertNotEqual(
                client.capturedMessageBatches[0].map(\.content), client.capturedMessageBatches[1].map(\.content))
            XCTAssertEqual(result.usage?.promptTokens, 110)
            XCTAssertEqual(result.usage?.completionTokens, 2_948)
            XCTAssertEqual(result.usage?.totalTokens, 3_058)
            XCTAssertEqual(telemetry.llmOperationProps.count, 1)
            XCTAssertEqual(telemetry.llmOperationProps.first?["completion_tokens"], "2948")
            XCTAssertEqual(telemetry.llmOperationProps.first?["retry_count"], "1")
        }
    }

    func testTruncatedButParseableJSONCannotBecomeSuccessAndStopsAfterTwoRequests() async throws {
        let telemetry = CardTelemetrySpy()
        Telemetry.configure(telemetry)
        let client = MockLLMClient()
        client.responseContent = Self.validMeetingJSON
        client.responseFinishReason = "length"
        let service = Self.service(client: client, config: .openai(apiKey: "test"))

        await XCTAssertThrowsErrorAsync {
            _ = try await service.generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)
        }

        XCTAssertEqual(client.chatCompletionCallCount, 2)
        XCTAssertEqual(telemetry.llmOperationProps.count, 1)
        XCTAssertEqual(telemetry.llmOperationProps.first?["outcome"], "failure")
    }

    func testMalformedAndEmptySynopsisRecoveryChangesPromptWithoutReplayingOutput() async throws {
        for badOutput in [
            "UNTRUSTED_MODEL_OUTPUT", "{\"topics\":[]}",
            "{\"synopsis\":\"   \",\"topics\":[],\"decisions\":[],\"actions\":[]}",
        ] {
            let client = MockLLMClient()
            client.responseContents = [badOutput, Self.validMeetingJSON]
            let service = Self.service(client: client, config: .anthropic(apiKey: "test"))

            _ = try await service.generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)

            XCTAssertEqual(client.chatCompletionCallCount, 2)
            XCTAssertEqual(client.capturedOptionBatches.map(\.maxTokens), [2_048, 2_048])
            XCTAssertNotEqual(
                client.capturedMessageBatches[0].map(\.content), client.capturedMessageBatches[1].map(\.content))
            XCTAssertFalse(client.capturedMessages.contains { $0.content.contains(badOutput) })
        }
    }

    func testBooleanCitationTimestampIsRejectedBeforeLLMSuccess() async throws {
        let telemetry = CardTelemetrySpy()
        Telemetry.configure(telemetry)
        let client = MockLLMClient()
        client.responseContent = """
            {"synopsis":"Synthetic release review.","topics":[],"actions":[],
             "decisions":[{"text":"Ship","quote":"Ship","startMs":true,"endMs":1000}]}
            """
        let service = Self.service(client: client, config: .openai(apiKey: "test"))

        await XCTAssertThrowsErrorAsync {
            _ = try await service.generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)
        }

        XCTAssertEqual(client.chatCompletionCallCount, 2)
        XCTAssertEqual(telemetry.llmOperationProps.count, 1)
        XCTAssertEqual(telemetry.llmOperationProps.first?["outcome"], "failure")
    }

    func testMissingUsageStaysUnknownAcrossRecoveryIncludingLocalCLI() async throws {
        for config in [LLMProviderConfig.openai(apiKey: "test"), .localCLI()] {
            let client = MockLLMClient()
            client.responseContents = ["not json", Self.validMeetingJSON]
            client.responseUsages = [nil, TokenUsage(promptTokens: 3, completionTokens: 4)]
            let telemetry = CardTelemetrySpy()
            Telemetry.configure(telemetry)

            let result = try await Self.service(client: client, config: config).generateKnowledgeCard(
                transcript: "Synthetic transcript", source: .meeting)

            XCTAssertNil(result.usage)
            XCTAssertNil(telemetry.llmOperationProps.first?["completion_tokens"])
            XCTAssertEqual(telemetry.llmOperationProps.count, 1)
            if config.id == .localCLI { XCTAssertNil(client.capturedOptions?.maxTokens) }
        }
    }

    func testProviderErrorsAndCancellationDoNotTriggerBlindRecovery() async throws {
        let errors: [Error] = [
            LLMError.requestTimedOut, LLMError.rateLimited,
            LLMError.providerError("response_format unsupported"), CancellationError(),
        ]
        for error in errors {
            let telemetry = CardTelemetrySpy()
            Telemetry.configure(telemetry)
            let client = MockLLMClient()
            client.chatCompletionError = error

            await XCTAssertThrowsErrorAsync {
                _ = try await Self.service(client: client, config: .openai(apiKey: "test"))
                    .generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)
            }

            XCTAssertEqual(client.chatCompletionCallCount, 1)
            XCTAssertEqual(telemetry.llmOperationProps.count, 1)
            XCTAssertEqual(
                telemetry.llmOperationProps.first?["outcome"], error is CancellationError ? "cancelled" : "failure")
            XCTAssertNil(telemetry.llmOperationProps.first?["completion_tokens"])
        }
    }

    func testTemporaryConfigurationLockRecoversBeforeAnyProviderRequest() async throws {
        let resolver = CardRecoveryContextResolver(busyReads: 2)
        let client = MockLLMClient()
        client.responseContent = Self.validMeetingJSON
        let telemetry = CardTelemetrySpy()
        Telemetry.configure(telemetry)
        let service = LLMService(client: client, contextResolver: resolver, cardRetrySleep: { _ in })

        _ = try await service.generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)

        XCTAssertEqual(resolver.readCount, 3)
        XCTAssertEqual(client.chatCompletionCallCount, 1)
        XCTAssertEqual(telemetry.llmOperationProps.count, 1)
        XCTAssertEqual(telemetry.llmOperationProps.first?["outcome"], "success")
        XCTAssertEqual(telemetry.llmOperationProps.first?["retry_count"], "0")
    }

    func testConfigurationLockExhaustionAndCancellationEmitOneTerminalWithoutProviderCall() async throws {
        for cancelled in [false, true] {
            let resolver = CardRecoveryContextResolver(busyReads: 100)
            let client = MockLLMClient()
            let telemetry = CardTelemetrySpy()
            Telemetry.configure(telemetry)
            let service = LLMService(
                client: client, contextResolver: resolver,
                cardRetrySleep: { _ in
                    if cancelled { throw CancellationError() }
                })

            await XCTAssertThrowsErrorAsync {
                _ = try await service.generateKnowledgeCard(transcript: "Synthetic transcript", source: .meeting)
            }

            XCTAssertEqual(resolver.readCount, cancelled ? 1 : 4)
            XCTAssertEqual(client.chatCompletionCallCount, 0)
            XCTAssertEqual(telemetry.llmOperationProps.count, 1)
            XCTAssertEqual(telemetry.llmOperationProps.first?["outcome"], cancelled ? "cancelled" : "failure")
        }
    }

    private static func service(client: MockLLMClient, config: LLMProviderConfig) -> LLMService {
        LLMService(
            client: client,
            contextResolver: StaticLLMExecutionContextResolver(
                context: LLMExecutionContext(providerConfig: config)))
    }
}

private final class CardRecoveryContextResolver: LLMExecutionContextResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let busyReads: Int
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }

    init(busyReads: Int) { self.busyReads = busyReads }

    func resolveContext() throws -> LLMExecutionContext? {
        try lock.withLock {
            reads += 1
            if reads <= busyReads { throw LLMConfigStore.StoreError.busy }
            return LLMExecutionContext(providerConfig: .openai(apiKey: "test"))
        }
    }
}
