import Foundation

/// USIエンジンのエラー
enum USIEngineError: Error, LocalizedError {
    case timeout(waitingFor: String)

    var errorDescription: String? {
        switch self {
        case .timeout(let waitingFor):
            return "エンジンの応答がありません（\(waitingFor) 待ちでタイムアウト）"
        }
    }
}

/// アプリ内で動くやねうら王とUSIプロトコルで通信するブリッジ。
///
/// エンジンは専用スレッドで `snapshogi_engine_start()`（＝リネームしたmain関数）を実行し、
/// 標準入出力をパイプに差し替えて対話する。プロセス全体のstdin/stdoutを乗っ取るため、
/// エンジン起動後は print() の出力もエンジン応答パイプに流れる点に注意
/// （アプリの通常動作には影響しない）。
final class USIEngine: @unchecked Sendable {
    static let shared = USIEngine()

    private let lock = NSLock()
    private var engineThreadStarted = false
    private var prepared = false
    /// アプリ → エンジン(stdin)
    private let commandPipe = Pipe()
    /// エンジン(stdout) → アプリ
    private let responsePipe = Pipe()
    private var lineBuffer = ""
    /// 差し替え前のstdout。テストランナー等がfd 1に依存しているため、
    /// 複製して生かしておき、エンジン出力もここへ転送する（ログにも残る）
    private var savedStdout: Int32 = -1

    private final class Waiter {
        let prefix: String
        var continuation: CheckedContinuation<String, Error>?
        init(prefix: String, continuation: CheckedContinuation<String, Error>) {
            self.prefix = prefix
            self.continuation = continuation
        }
    }
    private var waiters: [Waiter] = []
    /// 直近の go 以降に受け取った info 行（読み筋・評価値の抽出用）
    private var infoLines: [String] = []

    // MARK: - 起動

    private func startEngineThreadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !engineThreadStarted else { return }
        engineThreadStarted = true

        // 標準入出力をパイプへ差し替えてからエンジンスレッドを起動する。
        // 元のstdoutは複製して維持する（fd 1の参照が消えると、テストランナーの
        // 出力パイプがEOFになりプロセス異常終了と誤認されるため）
        savedStdout = dup(STDOUT_FILENO)
        dup2(commandPipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        dup2(responsePipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let savedStdout = self.savedStdout
        responsePipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // 元のstdoutにも転送（Xcodeのログで確認できるように）
            if savedStdout >= 0 {
                data.withUnsafeBytes { _ = write(savedStdout, $0.baseAddress, $0.count) }
            }
            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            self.consume(text)
        }

        let thread = Thread {
            _ = snapshogi_engine_start()
        }
        thread.name = "yaneuraou-engine"
        thread.stackSize = 8 << 20   // 探索の再帰が深いためスタックを広めに確保
        thread.start()
    }

    /// USIハンドシェイクとオプション設定（初回のみ）
    func prepare() async throws {
        startEngineThreadIfNeeded()
        lock.lock()
        let alreadyPrepared = prepared
        lock.unlock()
        guard !alreadyPrepared else { return }

        send("usi")
        _ = try await waitFor(prefix: "usiok", timeout: 10)
        // 置換表64MB: 16MBは駒得評価時代の設定で、NNUEの探索には手狭
        // （読み直しが増えて同じ思考時間でも浅くなる）。定跡ファイルは無効化
        send("setoption name USI_Hash value 64")
        send("setoption name Threads value 2")
        send("setoption name BookFile value no_book")
        // NNUE評価関数（水匠5）はバンドル直下の nn.bin を読む
        // （XcodeGenがApp/Resources/Eval/nn.binをバンドル直下に配置する）。
        // FV_SCALE=24 は水匠5の推奨値（配布ページ記載）
        if let evalDir = Bundle.main.resourcePath {
            send("setoption name EvalDir value \(evalDir)")
            send("setoption name FV_SCALE value 24")
        }
        // isreadyで評価関数ファイル（約61MB）の読み込みが走るため、タイムアウトは長めに
        send("isready")
        _ = try await waitFor(prefix: "readyok", timeout: 30)

        lock.lock()
        prepared = true
        lock.unlock()
    }

    // MARK: - 通信

    func send(_ command: String) {
        startEngineThreadIfNeeded()
        if let data = (command + "\n").data(using: .utf8) {
            commandPipe.fileHandleForWriting.write(data)
        }
    }

    /// 指定プレフィックスで始まる行が届くまで待つ
    func waitFor(prefix: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(prefix: prefix, continuation: continuation)
            lock.lock()
            waiters.append(waiter)
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pending = waiter.continuation
                waiter.continuation = nil
                self.waiters.removeAll { $0 === waiter }
                self.lock.unlock()
                pending?.resume(throwing: USIEngineError.timeout(waitingFor: prefix))
            }
        }
    }

    private func consume(_ text: String) {
        lock.lock()
        lineBuffer += text
        var resolved: [(CheckedContinuation<String, Error>, String)] = []
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(..<newlineRange.upperBound)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("info ") {
                infoLines.append(line)
            }
            for waiter in waiters where line.hasPrefix(waiter.prefix) {
                if let continuation = waiter.continuation {
                    waiter.continuation = nil
                    resolved.append((continuation, line))
                }
            }
            waiters.removeAll { $0.continuation == nil }
        }
        lock.unlock()
        for (continuation, line) in resolved {
            continuation.resume(returning: line)
        }
    }

    // MARK: - 解析

    /// 局面を解析して最善手（USI表記。例: "7g7f"）を返す
    func bestMove(sfen: String, movetimeMs: Int = 1000) async throws -> String {
        try await analyze(sfen: sfen, movetimeMs: movetimeMs, multiPV: 1).bestMove
    }

    /// 局面を解析して、最善手＋候補手（MultiPV）＋読み筋＋評価値を返す
    func analyze(sfen: String, movetimeMs: Int = 1000, multiPV: Int = 3) async throws -> AnalysisResult {
        try await prepare()
        send("setoption name MultiPV value \(multiPV)")
        lock.lock()
        infoLines.removeAll()
        lock.unlock()

        send("position sfen \(sfen)")
        send("go movetime \(movetimeMs)")
        let timeout = TimeInterval(movetimeMs) / 1000 + 10
        let line = try await waitFor(prefix: "bestmove", timeout: timeout)
        let parts = line.split(separator: " ")
        let best = parts.count >= 2 ? String(parts[1]) : ""

        lock.lock()
        let snapshot = infoLines
        lock.unlock()

        // multipvごとに最後（最深）のinfo行を採用する
        var latest: [Int: PVLine] = [:]
        for infoLine in snapshot {
            if let parsed = USIInfoParser.parse(infoLine) {
                latest[parsed.multipv] = parsed
            }
        }
        let sideToMove: Side = sfen.split(separator: " ").count >= 2 && sfen.split(separator: " ")[1] == "w" ? .gote : .sente
        return AnalysisResult(
            bestMove: best,
            lines: latest.values.sorted { $0.multipv < $1.multipv },
            sideToMove: sideToMove
        )
    }
}
