import Foundation

enum ClaudeVisionService {
    /// Analyze a webcam frame with Claude vision and return optimization recommendations.
    static func analyze(
        imageData: Data,
        previousImageData: Data? = nil,
        cameraName: String,
        currentSettings: UVCSettings,
        ranges: [String: UVCRange],
        model: String = "sonnet"
    ) async throws -> OptimizationResult {
        let prompt = buildPrompt(
            cameraName: cameraName,
            currentSettings: currentSettings,
            ranges: ranges,
            isFollowup: previousImageData != nil
        )

        var content: [[String: Any]] = []

        // If we have a previous image, send it first for before/after comparison
        if let prevData = previousImageData {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": prevData.base64EncodedString(),
                ] as [String: String],
            ])
        }

        content.append([
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": imageData.base64EncodedString(),
            ] as [String: String],
        ])

        content.append([
            "type": "text",
            "text": prompt,
        ])

        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": content,
            ] as [String: Any],
        ]

        let inputData = try JSONSerialization.data(withJSONObject: message)
        guard var inputStr = String(data: inputData, encoding: .utf8) else {
            throw ClaudeError.encodingFailed
        }
        inputStr += "\n"

        guard let claudePath = findClaude() else {
            throw ClaudeError.cliNotFound
        }

        let output = try await ShellRunner.run(
            executablePath: claudePath,
            arguments: [
                "--print", "--verbose",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--model", model,
                "--no-session-persistence",
            ],
            input: inputStr.data(using: .utf8),
            timeout: .seconds(120)
        )

        return try parseResponse(output)
    }

    private static func findClaude() -> String? {
        let paths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let result = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result, !result.isEmpty { return result }
        return nil
    }

    private static func parseResponse(_ output: String) throws -> OptimizationResult {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if json["type"] as? String == "result",
               let resultText = json["result"] as? String
            {
                return try parseRecommendations(resultText)
            }
        }
        throw ClaudeError.noResult
    }

    private static func parseRecommendations(_ text: String) throws -> OptimizationResult {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(
                    of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: #"\s*```$"#, with: "", options: .regularExpression)
        }

        if let data = cleaned.data(using: .utf8),
           let result = try? JSONDecoder().decode(OptimizationResult.self, from: data)
        {
            return result
        }

        // Try to extract JSON object from text
        if let range = cleaned.range(of: #"\{[\s\S]*\}"#, options: .regularExpression),
           let data = String(cleaned[range]).data(using: .utf8),
           let result = try? JSONDecoder().decode(OptimizationResult.self, from: data)
        {
            return result
        }

        throw ClaudeError.parseFailed(String(cleaned.prefix(500)))
    }

    // MARK: - Prompt

    private static func buildPrompt(
        cameraName: String,
        currentSettings: UVCSettings,
        ranges: [String: UVCRange],
        isFollowup: Bool
    ) -> String {
        let settingsJSON: String
        if let data = try? JSONEncoder().encode(currentSettings),
           let str = String(data: data, encoding: .utf8)
        {
            settingsJSON = str
        } else {
            settingsJSON = "{}"
        }

        let rangesStr = ranges
            .sorted(by: { $0.key < $1.key })
            .map { "- \($0.key): \($0.value.min)-\($0.value.max)" }
            .joined(separator: "\n")

        let comparisonNote = isFollowup ? """

        ## Comparison
        The FIRST image is BEFORE your previous adjustments. The SECOND image is AFTER.
        Compare them: did your changes improve things? If the second image is worse,
        partially revert. If better but not perfect, continue refining in the same
        direction with smaller adjustments.
        """ : ""

        return """
        You are a professional webcam calibration engineer. Analyze this webcam image
        and recommend UVC setting adjustments to make the person look natural and
        well-lit for a video call. The goal is a clean, professional image -- not a
        "perfect" one. Prioritize natural skin tones and avoiding artifacts.

        Camera: \(cameraName)
        Current settings: \(settingsJSON)
        Valid ranges: \(rangesStr)

        ## How each control works (use this to make informed adjustments)

        - **brightness** (0-255): Shifts the entire image lighter/darker. Mid-range
          (100-140) is typical for indoor lighting. Going above 170 washes out; below
          70 looks underexposed. Adjust in steps of 10-20.
        - **contrast** (0-255): Difference between darks and lights. 100-130 is
          natural. Above 150 crushes shadows and blows highlights. Below 80 looks flat
          and hazy. Keep conservative -- high contrast is the #1 cause of bad webcam
          images.
        - **saturation** (0-255): Color intensity. 100-130 is natural skin tone range.
          Above 150 makes skin look orange/red. Below 80 looks washed out. Err toward
          lower rather than higher.
        - **gain** (0-255): Signal amplification. Lower is better (less noise). Below
          30 is ideal. Above 60 introduces visible grain. Only raise gain if the image
          is too dark AND brightness is already near max.
        - **sharpness** (0-255): Edge enhancement. 100-140 is natural. Above 180
          creates halos around edges. Below 80 looks soft. Leave near default unless
          visibly soft or oversharpened.
        - **white_balance_temperature** (2800-7500): Color temperature in Kelvin.
          ~3200K = warm/tungsten, ~5000K = daylight, ~6500K = cloudy/cool.
          Only meaningful when auto_white_balance_temperature is OFF (0).
        - **exposure_time_absolute** (3-2047): Shutter speed in 0.1ms units.
          Lower = less motion blur but darker. Higher = brighter but more blur.
          ~250-500 is good for 30fps video calls. Only meaningful when
          auto_exposure_mode is MANUAL (1).
        - **auto_white_balance_temperature**: 1 = auto (camera decides WB), 0 = manual
          (you set white_balance_temperature). Use auto unless there's a persistent
          color cast the camera can't correct.
        - **auto_exposure_mode**: 8 = auto (camera controls exposure/gain),
          1 = manual (you control exposure_time_absolute and gain). Use auto unless
          the camera is hunting (flickering brightness) or consistently over/under
          exposing.

        ## Decision guidelines

        - Make SMALL adjustments. Change one or two settings by 10-20 units, not five
          settings by 50 units each. You can always refine on the next round.
        - If the image already looks decent, leave it alone or make minimal tweaks.
        - If auto modes are working well (no flickering, no color cast), leave them on.
        - If you see the camera fighting itself (brightness fluctuating, colors
          shifting), switch that auto mode OFF and set a fixed value.
        - Never set contrast and saturation both above 130 -- that combination always
          looks over-processed.
        \(comparisonNote)
        Respond with ONLY a JSON object (no markdown, no explanation):
        {
            "assessment": "1-2 sentence assessment of image quality and what needs fixing",
            "changes": {
                "brightness": 120,
                "contrast": 110
            },
            "auto_white_balance_temperature": 1,
            "auto_exposure_mode": 8
        }

        "changes" should ONLY include settings that need adjustment.
        If the image looks good, return empty changes: {}.
        Values must be integers within valid ranges.
        """
    }

    enum ClaudeError: LocalizedError {
        case cliNotFound
        case encodingFailed
        case noResult
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
            case .encodingFailed:
                return "Failed to encode request"
            case .noResult:
                return "No result in Claude output"
            case .parseFailed(let text):
                return "Could not parse recommendations: \(text)"
            }
        }
    }
}
