import Foundation

@MainActor
final class CouncilOrchestrator {

    private let registry: ProviderRegistry
    private var currentTask: Task<Void, Never>?

    enum Stage: Sendable {
        case firstOpinions(completed: Int, total: Int)
        case peerReview(completed: Int, total: Int)
        case chairmanSynthesis
        case complete
    }

    init(registry: ProviderRegistry) {
        self.registry = registry
    }

    func execute(
        _ request: AIRequest,
        council: CouncilConfig,
        onStageUpdate: @escaping @Sendable (Stage) -> Void
    ) async throws -> AIResponse {

        let members = council.memberProviderIDs.compactMap { registry.provider(for: $0) }
        guard let chairman = registry.provider(for: council.chairmanProviderID) else {
            throw CouncilError.chairmanUnavailable
        }
        guard !members.isEmpty else {
            throw CouncilError.noMembers
        }

        // Stage 1: First Opinions
        let opinions = try await collectOpinions(
            request: request,
            members: members,
            timeout: council.timeoutSeconds,
            onProgress: { completed, total in
                onStageUpdate(.firstOpinions(completed: completed, total: total))
            }
        )

        // Stage 2: Peer Review
        onStageUpdate(.peerReview(completed: 0, total: members.count))
        let reviews = try await collectReviews(
            opinions: opinions,
            members: members,
            anonymized: council.reviewAnonymized,
            timeout: council.timeoutSeconds,
            originalTask: request.task,
            onProgress: { completed, total in
                onStageUpdate(.peerReview(completed: completed, total: total))
            }
        )

        // Stage 3: Chairman Synthesis
        onStageUpdate(.chairmanSynthesis)
        let synthesis = try await synthesize(
            request: request,
            opinions: opinions,
            reviews: reviews,
            chairman: chairman,
            anonymized: council.reviewAnonymized
        )

        onStageUpdate(.complete)
        return synthesis
    }

    /// Streaming variant — runs stages 1-2 internally, streams only the chairman's Stage 3 output.
    /// Status updates for stages 1-2 are reported via onStageUpdate callback.
    func executeWithStreaming(
        _ request: AIRequest,
        council: CouncilConfig,
        onStageUpdate: @escaping @Sendable (Stage) -> Void
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                do {
                    let response = try await execute(request, council: council, onStageUpdate: onStageUpdate)
                    continuation.yield(response.text)
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func cancelExecution() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Stage 1: First Opinions

    private func collectOpinions(
        request: AIRequest,
        members: [any AIProvider],
        timeout: TimeInterval,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> [(providerID: String, response: AIResponse)] {
        var results: [(providerID: String, response: AIResponse)] = []
        let total = members.count

        await withTaskGroup(of: (String, AIResponse?).self) { group in
            for member in members {
                group.addTask {
                    do {
                        let response = try await withThrowingTaskGroup(of: AIResponse.self) { inner in
                            inner.addTask { try await member.complete(request) }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(timeout))
                                throw CouncilError.memberTimeout(member.id)
                            }
                            let result = try await inner.next()!
                            inner.cancelAll()
                            return result
                        }
                        return (member.id, response)
                    } catch {
                        return (member.id, nil)
                    }
                }
            }

            for await (id, response) in group {
                if let response {
                    results.append((providerID: id, response: response))
                }
                onProgress(results.count, total)
            }
        }

        guard !results.isEmpty else {
            throw CouncilError.allMembersTimedOut
        }
        return results
    }

    // MARK: - Stage 2: Peer Review

    private func collectReviews(
        opinions: [(providerID: String, response: AIResponse)],
        members: [any AIProvider],
        anonymized: Bool,
        timeout: TimeInterval,
        originalTask: AITask,
        onProgress: @escaping (Int, Int) -> Void
    ) async throws -> [(providerID: String, review: String)] {
        var reviews: [(providerID: String, review: String)] = []
        let respondedMembers = members.filter { m in opinions.contains { $0.providerID == m.id } }
        let total = respondedMembers.count

        let reviewPrompt = buildReviewPrompt(opinions: opinions, anonymized: anonymized)

        await withTaskGroup(of: (String, String?).self) { group in
            for member in respondedMembers {
                group.addTask {
                    let request = AIRequest(
                        prompt: reviewPrompt,
                        systemPrompt: "You are reviewing responses from other AI models. Provide a critique and ranking of each response.",
                        maxTokens: 1000,
                        temperature: 0.3,
                        task: originalTask
                    )
                    do {
                        let response = try await withThrowingTaskGroup(of: AIResponse.self) { inner in
                            inner.addTask { try await member.complete(request) }
                            inner.addTask {
                                try await Task.sleep(for: .seconds(timeout))
                                throw CouncilError.memberTimeout(member.id)
                            }
                            let result = try await inner.next()!
                            inner.cancelAll()
                            return result
                        }
                        return (member.id, response.text)
                    } catch {
                        return (member.id, nil)
                    }
                }
            }

            for await (id, review) in group {
                if let review {
                    reviews.append((providerID: id, review: review))
                }
                onProgress(reviews.count, total)
            }
        }

        return reviews
    }

    // MARK: - Stage 3: Chairman Synthesis

    private func synthesize(
        request: AIRequest,
        opinions: [(providerID: String, response: AIResponse)],
        reviews: [(providerID: String, review: String)],
        chairman: any AIProvider,
        anonymized: Bool
    ) async throws -> AIResponse {
        let synthesisPrompt = buildSynthesisPrompt(
            originalRequest: request.prompt,
            opinions: opinions,
            reviews: reviews,
            anonymized: anonymized
        )

        let synthesisRequest = AIRequest(
            prompt: synthesisPrompt,
            systemPrompt: "You are the chairman of an AI council. Synthesize the best final answer from the responses and peer reviews provided. Focus on accuracy and completeness.",
            maxTokens: request.maxTokens,
            temperature: 0.4,
            task: request.task
        )

        return try await chairman.complete(synthesisRequest)
    }

    // MARK: - Prompt Building

    private func buildReviewPrompt(
        opinions: [(providerID: String, response: AIResponse)],
        anonymized: Bool
    ) -> String {
        var prompt = "Review the following responses and provide a critique and ranking:\n\n"
        for (index, opinion) in opinions.enumerated() {
            let label = anonymized ? "Response \(Character(UnicodeScalar(65 + index)!))" : opinion.providerID
            prompt += "### \(label)\n\(opinion.response.text)\n\n"
        }
        prompt += "Provide your critique of each response and rank them from best to worst."
        return prompt
    }

    private func buildSynthesisPrompt(
        originalRequest: String,
        opinions: [(providerID: String, response: AIResponse)],
        reviews: [(providerID: String, review: String)],
        anonymized: Bool
    ) -> String {
        var prompt = "Original question: \(originalRequest)\n\n"
        prompt += "## Responses\n\n"
        for (index, opinion) in opinions.enumerated() {
            let label = anonymized ? "Response \(Character(UnicodeScalar(65 + index)!))" : opinion.providerID
            prompt += "### \(label)\n\(opinion.response.text)\n\n"
        }
        prompt += "## Peer Reviews\n\n"
        for (index, review) in reviews.enumerated() {
            let label = anonymized ? "Reviewer \(Character(UnicodeScalar(65 + index)!))" : review.providerID
            prompt += "### \(label)\n\(review.review)\n\n"
        }
        prompt += "Based on all responses and reviews, synthesize the best final answer."
        return prompt
    }
}

// MARK: - Errors

enum CouncilError: LocalizedError {
    case chairmanUnavailable
    case noMembers
    case memberTimeout(String)
    case allMembersTimedOut

    var errorDescription: String? {
        switch self {
        case .chairmanUnavailable: return "Chairman model is not available"
        case .noMembers: return "No council members available"
        case .memberTimeout(let id): return "Council member \(id) timed out"
        case .allMembersTimedOut: return "All council members timed out"
        }
    }
}
